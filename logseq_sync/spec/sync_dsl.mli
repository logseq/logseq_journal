(** {1 TLDR}

    Describe indexed Sync workflows over the existing Core, Worker and runner
    protocols, without replacing their authority or persistence contracts.
    A [('before, 'after, 'value) t] is a deferred program, not an I/O result.
    {!branch} gives each operation separate success and failure postconditions;
    {!bind} composes only matching state indices. The interpreter delegates
    serialized Core turns and actual I/O to the existing Worker and its runner;
    the Worker remains the sole installed-state owner.

    Indices describe one graph lane, not the whole application's current graph.
    Several lanes may run concurrently under one account (at most three resident
    graphs, as in Core). Selection and presentation never change graph identity.
    OCaml values are duplicable: indices do NOT prove linear use, unique graph or
    account identity, current generations, durable commit, or physical retirement.
    The interpreter validates these facts at admission and again at completion.

    Primary signatures (declared below after their dependencies):
    {[
      val return : 'value -> ('state, 'state, 'value) t
      val bind : ('before, 'middle, 'value) t
        -> ('value -> ('middle, 'after, 'result) t)
        -> ('before, 'after, 'result) t
      val branch : ('before, 'success, 'failure, 'value, 'error) operation
        -> ok:('value -> ('success, 'after, 'result) t)
        -> error:('error -> ('failure, 'after, 'result) t)
        -> ('before, 'after, 'result) t
    ]}
    Queue admission is not execution, durable acknowledgement or presentation.
    Cancellation is not rollback. Shutdown requires actual I/O, callbacks,
    database owners and native leases to retire; a cancelled fiber is not proof.
    This is a proposed virtual-module contract, not an implemented adapter.
    It introduces no new persistent store, global cache or Dune registration. *)

(** {1 Minimal usage example}

    The caller supplies [runtime], a current detached [cursor], and [report]
    which handles every structured failure. Run this outside the serial pump:
    {[
      let program =
        branch restore_local
          ~ok:(fun attachment ->
            bind (observe ()) (fun view ->
              branch (begin_drain Ready_graph)
                ~ok:(fun () ->
                  branch finish_retirement
                    ~ok:(fun () -> return (attachment, view))
                    ~error:abort)
                ~error:abort))
          ~error:abort
      in
      match execute runtime cursor program with
      | Finished (retired_cursor, value) -> Ok (retired_cursor, value)
      | Faulted (current, error) -> report current error
    ]}
    [restore_local] never initiates network traffic. A missing key or mirror is
    returned explicitly; callers can choose the preparation/unlock or online
    recovery paths instead. [abort] preserves the actual failure-branch cursor.
    The caller's event pump and Worker/runner owners remain live until retirement
    finishes. Failure retains cleanup obligations, not a pretend retired cursor. *)

(** {1 Construction and validation} *)

module Core = Logseq_sync_pure_reducer.Core
module Transfer = Logseq_sync_pure_reducer.Asset_transfer
module Protocol = Logseq_sync_pure_reducer.Sync_protocol
module Runner = Logseq_sync_effect_runner.Effect_runner
module Codec = Logseq_sync_effect_runner.Asset_codec
module Worker = Logseq_db_worker
module Read = Worker_pure_read
module Mutation = Logseq_db_worker_contract.Worker_pure_mutation
module Overlay = Logseq_overlay_db.Types
module Asset = Logseq_db_types.Asset_descriptor

(** Host and graph typestates occupy different lanes. [ready] means a usable
    attached local mirror, not connectivity, an empty outbox or presentation.
    [preparing] may own staging and key preparation but grants no mirror reads.
    [locked] owns an exact pending challenge, not an attached encrypted mirror. *)
type serving
type stopping
type stopped
type detached
type preparing
type locked
type ready
type draining
type retired

type _ phase =
  | Serving : serving phase
  | Stopping : stopping phase
  | Stopped : stopped phase
  | Detached : detached phase
  | Preparing : preparing phase
  | Locked : locked phase
  | Ready : ready phase
  | Draining : draining phase
  | Retired : retired phase

type _ graph_phase =
  | Detached_graph : detached graph_phase
  | Preparing_graph : preparing graph_phase
  | Locked_graph : locked graph_phase
  | Ready_graph : ready graph_phase

type runtime
type 'state cursor
type packed_cursor = Cursor : 'state phase * 'state cursor -> packed_cursor

(** The interpreter creates process-local cursors for its registration, lane,
    revision and captured execution identity. Host cursors have no graph; graph
    cursors pin origin/user/graph even before an execution generation is allocated.
    Another accepted program consumes that cursor revision at runtime, not in
    OCaml's type system. Core background progress alone does not consume it, but
    incompatible phase or owner changes revoke it. Retained cleanup owners remain
    reachable after revocation. No cursor is serialized or reconstructed from UI. *)
type owner =
  { account : Core.account_scope option
  ; graph_id : Core.graph_id option
  ; execution_scope : Core.graph_scope option
  }

type error =
  | Configuration of string
  | Core_failure of Core.effect_error
  | Worker_failure of string
  | Asset_failure of Core.asset_failure
  | Protocol_failure of Protocol.codec_error
  | Read_failure of Read.error
  | Local_unavailable of Core.local_unavailability
  | Unlock_required of Core.unlock_challenge
  | Unlock_failed of Core.unlock_recovery
  | Stale_owner of owner
  | Busy of owner
  | Invalid_request of string
  | Capacity_exceeded of string
  | Cancelled
  | Unknown_outcome of string
  | Cleanup_failed of string

(** Validation is bounded and performs no catalog/mirror scan. These are explicit
    per-runtime admission limits, not a new unbounded command/event queue. The
    adapter must also honor Core response/artifact/batch limits, Transfer active,
    foreground-reserved/pending/retry limits and the runner's byte/cache budgets.
    Programs are bounded to 1..128, observers to 1..1024 and demands to 1..512,
    owned file/staging/native-lease resources to 1..1024 in total,
    notifications to 1..4096, page items to 1..4096, page bytes to 1..16777216,
    and interpreted steps per program to 1..65536. All bounds are inclusive.
    Invalid or unsupported bounds are errors; no silent truncation of work.
    Overflow rejects admission or coalesces observation invalidations; it never
    evicts live resources, loses cleanup ACKs or drops durable outcomes. Settled
    entries are pruned using existing monotonic registration/ticket fences;
    unresolved owners retain their slots and cause backpressure. *)
type limits
val limits
  : maximum_programs:int
  -> maximum_observers:int
  -> maximum_pending_notifications:int
  -> maximum_asset_demands:int
  -> maximum_owned_resources:int
  -> maximum_page_items:int
  -> maximum_page_bytes:int
  -> maximum_program_steps:int
  -> (limits, error) result

type attachment =
  { scope : Core.graph_scope
  ; sync : Overlay.sync_view
  }

(** Required implementation-side bridge at the existing Worker-owned boundary.
    These capabilities do NOT exist as a complete adapter in today's Worker.mli:
    asset/protected results go to private waiters and sync_view is not exposed by
    coordination snapshots. They must be supplied by a future authorized adapter,
    not reconstructed by polling presentation state or opening another database.
    This proposal does not authorize that implementation/contract work.

    Callbacks run off the serial consumer, use the original Core tickets/waiters,
    and deliver only exact scoped completions. [local_restore] must preserve
    local-only admission for this lane even if another resident is online; it
    may not feed a Mirror_absent event that silently starts remote bootstrap.
    It returns only after actual Worker attachment; partial cleanup failures
    preserve the real owner in authoritative coordination for [recover].
    Supplied capabilities are trusted interpreter dependencies, not untrusted
    UI booleans or compiler-proven authority. Validation checks availability and
    shape without calling them or scanning data; execution rechecks identities. *)
type bridge
val bridge
  : asset:(Core.asset_request -> Core.asset_result)
  -> protected_value:(Core.protected_request -> Core.protected_result)
  -> inspect_sync:(Core.graph_scope -> (Overlay.sync_view, error) result)
  -> local_restore:(account:Core.account_scope -> graph_id:Core.graph_id
       -> (attachment, error) result)
  -> (bridge, error) result

(** A facade ABOVE the existing Worker, not a dependency of its reducer/runner.
    The caller constructs Worker and its Sync runner using their existing config,
    Eio runtime, TLS/authenticator, token provider, secrets, crypto, artifact store
    and local-store APIs. [create] borrows that Worker, registers one authoritative
    coordination outlet and returns a host lane. It neither forks another Core
    owner nor replaces an existing registration without authorization. [sw] owns
    only facade tasks; the caller retains the Worker domain and runner switches.
    Registration failure leaves no live facade. No global cache or new durable
    format is introduced. Registration IDs must follow the host's monotonic policy. *)
val create
  : sw:Eio.Switch.t -> worker:Worker.t -> bridge:bridge
  -> registration:int64 -> limits:limits
  -> (runtime * serving cursor, error) result

(** Reserve one graph lane for an authorized catalog graph of the exact current
    logical account. Reject duplicate lanes and existing attached owners; use
    [recover] to adopt an existing resident instead. Scope generations are obtained
    from Core/Worker, never guessed from the graph UUID. Admission capacity counts
    preparing and cleanup owners as well as live programs. *)
val lane
  : runtime -> account:Core.account_scope -> graph_id:Core.graph_id
  -> (detached cursor, error) result

(** {1 Capability details} *)

(** {2 Indexed composition and execution} *)

type ('before, 'after, 'value) t
type ('before, 'success, 'failure, 'value, 'error) operation

val return : 'value -> ('state, 'state, 'value) t
val bind
  : ('before, 'middle, 'value) t
  -> ('value -> ('middle, 'after, 'result) t)
  -> ('before, 'after, 'result) t
val branch
  : ('before, 'success, 'failure, 'value, 'error) operation
  -> ok:('value -> ('success, 'after, 'result) t)
  -> error:('error -> ('failure, 'after, 'result) t)
  -> ('before, 'after, 'result) t

(** Terminate with the actual branch state and cause. It does not manufacture the
    polymorphic ['after], release resources, retry, or return a successful value. *)
val abort : error -> ('before, 'after, 'value) t

type ('after, 'value) execution =
  | Finished of 'after cursor * 'value
  | Faulted of packed_cursor * error

(** Reserve the exact cursor revision before executing; one program at a time per
    lane, concurrent programs on different graph lanes. Host mutations fence their
    captured lanes rather than relying on focus. [execute] may suspend and MUST
    NOT run inside Worker's serial consumer or non-yielding notification callback.
    Cancellation/host revocation/incompatible external events return [Faulted] with
    actual retained state, even if an operation's ordinary failure index differs.
    Unexpected exceptions retain diagnostic causes and cleanup obligations.
    Success is delivered only after the operation-specific acknowledgement.
    Construction/return/bind perform no Sync I/O; branch callbacks run only when
    interpreting that branch and must terminate without yielding or side effects.
    There is no unrestricted lift-I/O, cursor cast or same-lane parallel operator.
    Exhausting the step budget faults with the actual cursor and retained owners,
    not a partial successful program. Acknowledged requests cannot be undone by
    a later callback exception. Worker turns install next state before ordered
    Run/Delegate/Publish interpretation; completions queue later serialized turns,
    never recursively step the reducer. *)
val execute
  : runtime -> 'before cursor -> ('before, 'after, 'value) t
  -> ('after, 'value) execution

(** {2 Accounts, residency and local-first startup} *)

type account_input = Restore_local of string | Authenticated of string option
val reconcile_account : account_input -> (serving, serving, serving, unit, error) operation
val refresh_catalog
  : Core.startup_scope -> (serving, serving, serving, Core.graph Rrbvec.t, error) operation
val request_sign_in
  : Core.startup_scope -> (serving, serving, serving, unit, error) operation
val request_graph_picker : (serving, serving, serving, unit, error) operation

(** Reconciliation may revoke every graph cursor. Origin and user are both
    identity; same user text at another origin is a different account. Account,
    graph, connection and lifecycle generations fence execution independently
    from presentation. Restoring a cached account is not online authentication.
    Local feed acknowledgement is deliberately inert and does NOT authorize
    network work. Only the exact eligible Timeline_presented event or explicit
    user online action opens the existing network gate. Feed completion is not
    presentation. Scope-stale requests return errors, not hangs. *)
val acknowledge_local_feed : (serving, serving, serving, unit, error) operation
val set_residents
  : Core.graph_id list -> (serving, serving, serving, Core.graph_scope list, error) operation
val select_visible
  : Core.graph_id -> (serving, serving, serving, Core.timeline_scope, error) operation
val timeline_presented
  : Core.timeline_scope -> (serving, serving, serving, unit, error) operation
val set_foreground
  : foreground:bool -> lifecycle_generation:Core.lifecycle_generation
  -> (serving, serving, serving, unit, error) operation

(** At most three unique authorized resident graphs, matching Core's ordered
    roster. Focus changes neither retire a background graph nor retarget its
    requests, outbox, keys or asset consumers. Resident removal cancels admission
    but retained physical owners must still drain. Presentation acknowledgement
    matches account, graph and presentation generations, not merely UUID. *)

(** Offline restore inspects the cached catalog, mirror and wrapped local keys.
    No network is initiated by this operation. Success requires real Worker
    attachment and its sync view; missing/corrupt mirror, account or key is an
    explicit failure. Partial resources must settle before the detached error
    branch; otherwise [Faulted] carries a preparing/draining owner. *)
val restore_local : (detached, ready, detached, attachment, error) operation

(** Prepare the selected graph's existing Core startup attempt. No destructive
    snapshot activation is inferred from a missing mirror or network error.
    Unencrypted or already-unlocked graphs can use [activate_prepared]; encrypted
    attempts first obtain [challenge] and use [unlock]. *)
val prepare : (detached, preparing, detached, unit, error) operation
val challenge
  : (preparing, locked, preparing, Core.unlock_challenge, error) operation
val activate_prepared : (preparing, ready, preparing, attachment, error) operation
val unlock
  : Core.unlock_challenge -> password:string
  -> (locked, ready, locked, Core.unlock_attached, error) operation

(** Core creates challenge/submission/attached evidence for the exact attempt.
    Password submission alone is not unlock success: success follows key access,
    any required bootstrap, and actual attachment. Preserve Retry_password versus
    Retry_preparation in [Unlock_failed]; this is recovery information, not an
    automatic retry policy. Retired/replaced challenges cannot unlock another
    lane. A failed preparation needing a new challenge is recovered through
    [recover], not coerced into the old [locked] cursor. Never log passwords,
    raw tokens, decrypted values or private key packages. *)
val recover_online
  : Core.timeline_scope -> (serving, serving, serving, unit, error) operation
val cancel_online
  : Core.startup_scope -> (serving, serving, serving, unit, error) operation

(** {2 Snapshot, incremental sync and durable outbox} *)

(** Bootstrap uses Core's baseline, metadata, bounded download and exact staged
    artifact/activation receipts. The Worker validates streamed rows and key-bound
    unprotection batches, then atomically commits activation before attachment.
    Same-scope replacement attempts are distinct. Obsolete downloads are cleaned;
    no caller can substitute a path, cursor or key for Core's activation request.
    Existing unsynchronized content is not silently overwritten. *)
val bootstrap : (preparing, ready, preparing, attachment, error) operation

(** Inspect the exact graph's durable sync token, cursor, revision and outbox.
    Incremental pull/submission remain owned by Core's WebSocket protocol; do not
    expose arbitrary authoritative commits or user-supplied server cursors. *)
val inspect_sync : (ready, ready, ready, Overlay.sync_view, error) operation
val notify_outbox_changed : (ready, ready, ready, unit, error) operation

(** Notify success means Core accepted the scoped invalidation, NOT remote ACK.
    Prepared/sent/accepted/rejected outbox transitions preserve their expected
    sync token and original request. A changed durable token can supersede an
    uncommitted preparation; an unchanged failed request is not retried. Server
    acceptance, local authoritative commit, durable outbox cleanup, and timeline
    presentation are separate facts. On lost ACK/restart inspect durable state;
    never infer rollback from cancellation or blindly resend an unknown outcome.
    Authoritative deferred batches retain their original scope and retry only
    when the existing dependency/token protocol permits progress. *)

(** Read/mutation capability is delegated to the actual scoped Worker owner;
    this facade never opens a second overlay database or implements pagination. *)
val read : Read.packed_query -> (ready, ready, ready, Read.answer, error) operation
val mutate
  : Mutation.durable_intent -> (ready, ready, ready, Mutation.outcome, error) operation
val confirm_mutation
  : read:Read.packed_query -> intent:Mutation.durable_intent
  -> original:(string * string * string)
  -> (ready, ready, ready, Read.answer, error) operation
val recover_mutations
  : after:int64 option -> maximum_items:int -> maximum_bytes:int
  -> (ready, ready, ready, Mutation.recovery_page, error) operation
val acknowledge_mutation
  : intent:Mutation.durable_intent -> original:(string * string * string) option
  -> (ready, ready, ready, unit, error) operation

(** [Mutation.outcome] keeps its own durable failure/unknown branches; operation
    success only means a typed outcome was delivered. Recovery pages retain the
    Worker's continuation/absence meaning and caller bounds; validation never
    scans all mutations. Confirmation is an authoritative read, not presentation.
    Acknowledgement matches original durable evidence and does not erase a newer
    intent. All callbacks recheck registration, graph incarnation and fences. *)

(** {2 Assets, protected values and native leases} *)

type demand
type lease
type asset_file
type staged_file
type observation

(** Unlike Worker.import_receipt, the preview is already an owned DSL lease.
    Import must reserve its slot before acquiring the native retain; an abandoned
    or cancelled delivery is handed to the Worker's orphan-retain cleanup owner.
    It must never leak the raw receipt.preview retain outside this ledger. *)
type import_receipt =
  { operation : Core.graph_id
  ; graph_generation : Core.graph_generation
  ; scope : Core.graph_scope
  ; target : Core.graph_id
  ; asset : Asset.t
  ; file_type : string
  ; preview : (lease * string) option
  }

(** Every ownership-bearing Core asset result is adopted before publication.
    These are process-local resources, not untracked raw handle strings. Paths
    become usable by native consumers only through an acquired [lease]. *)
type asset_value =
  | Asset_unit
  | Asset_cached of asset_file option
  | Asset_downloaded of asset_file
  | Asset_staged of { file : staged_file; checksum : string; size : int64 }
  | Asset_retained of (lease * string) option
  | Asset_pruned of int
  | Asset_retry_elapsed

(** The facade allocates bounded consumer/operation IDs under its registration;
    these resources bind exact graph scope, version, consumer and native owner.
    They are not paths or durable receipts. Retirement revokes acquisition but
    does not invalidate the original release obligation. Demand count AND the
    aggregate descriptor entries across all demands are bounded by
    maximum_asset_demands. Every owned file, staged file and native retain
    consumes a maximum_owned_resources slot, including repeated retains of the
    same bytes. Reserve before I/O, or reject without acquiring; failed release
    retains its slot until physical ACK. Demand-internal handles and orphaned
    delivery cleanup also count, so sequential programs cannot grow the ledger
    without bound. Cleanup is never blocked by acquisition capacity. *)
val demand_assets
  : consumer:string -> priority:Transfer.priority -> assets:Asset.t Rrbvec.t
  -> (ready, ready, ready, demand, error) operation
val replace_demand
  : demand -> priority:Transfer.priority -> assets:Asset.t Rrbvec.t
  -> (ready, ready, ready, unit, error) operation
val asset_availability
  : demand -> (ready, ready, ready, (Core.graph_id * Transfer.availability) list, error) operation
val retain_asset
  : handle:string -> (ready, ready, ready, (lease * string) option, error) operation
val import_asset
  : Logseq_db_types.Asset_import.t
  -> (ready, ready, ready, import_receipt, error) operation
val retain_imported
  : operation:Core.graph_id -> (ready, ready, ready, (lease * string) option, error) operation

(** [None] means no retainable file for that exact handle/operation; it is not an
    empty file or proof of remote absence. A successful lease keeps the returned
    native path alive until checked release. Foreign handles are errors.
    Transfer demand uses explicit descriptors/local checksum/remote version;
    it does not scan the graph for assets. Stale successful downloads still
    release handles. Only network failures schedule retries; authentication,
    checksum, storage, locked, invalid content and missing source stay explicit.
    Locked work waits for actual unlock; missing remote versions may remain
    Waiting_remote rather than being reported as a successful empty download.

    Download/put/stage/publish/prune requests use existing Core asset actions,
    limits and typed completions via [asset_action]. Only cleanup actions are
    allowed after retirement through the dedicated release operations below.
    Encrypted wire envelopes are verified with Codec; a malformed envelope never
    falls back to raw bytes. Asset bytes never become business request payloads. *)
val asset_action
  : operation:string -> Core.asset_action
  -> (ready, ready, ready, asset_value, error) operation
val protected_action
  : operation:string -> Core.protected_action
  -> (ready, ready, ready, Core.protected_value, error) operation

(** Reject raw release, close/deletion/account-deletion actions in [asset_action]:
    their authority belongs to dedicated resource/lifecycle protocols. File input
    references must be current resources of this lane; arbitrary strings confer
    no retain or prune authority. No Asset_deletion_prepared result is admitted.
    Validate key handle scope and request/result shape at runtime. No raw key
    extraction is provided. Preserve Asset_with_cause and crypto error categories.
    Normal operation IDs cannot impersonate another consumer or cleanup ticket. *)
val asset_file_reference : asset_file -> string
val staged_file_reference : staged_file -> string

(** References permit existing Core action inputs, never direct native reads.
    These accessors grant no ownership, and runtime validation remains mandatory. *)
val recover_import_inputs
  : after:int64 option -> maximum_items:int -> maximum_bytes:int
  -> (ready, ready, ready, Logseq_db_types.Asset_import.Recovery.page, error) operation
val confirm_import_input
  : input:string
  -> (ready, ready, ready, Logseq_db_types.Asset_import.Recovery.item option, error) operation
val acknowledge_import_input
  : input:string -> prepared:string -> (ready, ready, ready, unit, error) operation

(** {1 Lifecycle and recovery} *)

(** Logical cancellation stops new workflow work and requests cancellation of
    exact tickets; already committed effects and retained files remain owned.
    A cancellation object is per admitted execution, created by [start]. *)
type cancellation
type ('after, 'value) running
val start
  : runtime -> 'before cursor -> ('before, 'after, 'value) t
  -> (('after, 'value) running * cancellation, error) result
val cancel : runtime -> cancellation -> (unit, error) result
val await : ('after, 'value) running -> ('after, 'value) execution

(** [execute] is the start/await convenience path, with identical reservations.
    [start] rejection performs no program operations and consumes no cursor.
    [cancel] admission does not acknowledge a physical join. [await] is repeatable
    for the same terminal result, not a second execution. Running/cancellation
    values are process-local and belong to one runtime registration. *)

(** Graph draining is irreversible within an incarnation. Both ordinary branches
    are draining: failure after the fence cannot hand back ready authority.
    Rejection before fencing is a [Faulted] result carrying the original state.
    Preparation/unlock cancellation still cleans artifacts and secret handles. *)
val begin_drain : 'state graph_phase -> ('state, draining, draining, unit, error) operation
val finish_retirement : (draining, retired, draining, unit, error) operation

(** Retirement fences the exact owner; releases observers/demands, quiesces
    writers, joins snapshot/crypto/upload/asset tasks and callback posting, closes
    graph/storage subscriptions, and requires Graph_detached/Websocket_retired
    for retained owners. Outstanding native leases or failed physical cleanup
    keep [draining]; the original handles remain releasable. A read-only Await_io
    or Await_asset_operations barrier grants no host deletion permit. New socket
    admission waits for exact old-owner retirement, including cancelled setup.
    Duplicate/unrelated stale completions do not revive authority; cleanup ACKs
    still match retained original owners after generation changes. *)

(** Release is state-polymorphic so a retained original owner can clean up after
    graph/account replacement or shutdown. The runtime checks the resource's
    producer, not the current selected graph. Failure retains the same resource
    and cause; repeated successful releases are idempotent. [abandon_lease]
    transfers an unpublished native retain to the Worker's orphan cleanup owner,
    never falsely acknowledges physical release to the client. *)
val release_asset_file : asset_file -> ('state, 'state, 'state, unit, error) operation
val release_staged_file : staged_file -> ('state, 'state, 'state, unit, error) operation
val release_lease : lease -> ('state, 'state, 'state, unit, error) operation
val abandon_lease : lease -> ('state, 'state, 'state, unit, error) operation
val release_demand : demand -> ('state, 'state, 'state, unit, error) operation
val release_observation : observation -> ('state, 'state, 'state, unit, error) operation

(** {2 Host permission and physical local-copy deletion} *)

(** Reuse the existing Worker handoff plan/receipt rather than inventing a DSL
    permit. The caller supplies its authoritative baseline/version/registration,
    expected scopes and an explicit Normal/Force choice. Only the Worker captures
    actual physical scopes and copy identity. Preparing freezes the exact target,
    drains owners and native leases, and returns the original one-use receipt.
    Force is not automatic permission to discard unsynchronized user content. *)
val prepare_host_change
  : Worker.host_plan
  -> (serving, serving, serving, Worker.Pure_reducer.Host_handoff.receipt, error) operation
type host_application =
  | Bound_action_finished
  | Permission_consumed

val apply_host_change
  : Worker.Pure_reducer.Host_handoff.receipt
  -> (serving, serving, serving, host_application, error) operation
val confirm_host_change
  : Worker.Pure_reducer.Host_handoff.receipt
  -> (serving, serving, serving, bool, error) operation

(** Receipt consumption is not completion of a host's external action. For
    Close_graph/Remove_graph, [Bound_action_finished] follows the bound physical
    terminal action. For Replace_account/Stop_connection, current Worker apply
    only consumes permission and returns [Permission_consumed]; the host still
    performs its account reconciliation or connection stop. Neither apply nor
    confirm fabricates acknowledgement of that external action. Confirmation
    distinguishes the exact consumed receipt from foreign/unavailable state,
    preserving its error rather than treating it as absence. The host supplies
    user confirmation before destructive removal. Current/unauthorized graphs
    and overlapping flights remain rejected.

    Local deletion preserves the catalog and selection; it uses a retirement
    transaction ID, exclusive mirror-generation witness, frozen upload intents
    and a durable retired asset namespace. Existing journals reconcile crashes;
    commit/cancel replay only their captured namespace, never a replacement cache.
    Consumed handoff exclusivity lasts until its bound physical action finishes.
    Failed closes retain fences and obligations. This facade adds no journal. *)
val delete_local_copy
  : account_generation:Core.account_generation -> graph_id:Core.graph_id
  -> (serving, serving, serving, unit, error) operation

val begin_shutdown : (serving, stopping, stopping, unit, error) operation
val finish_shutdown : (stopping, stopped, stopping, unit, error) operation

(** Shutdown retires this facade's programs and registration through checked
    Worker coordination release, including all captured old-account scopes and
    optional account I/O/asset cleanup. It does not join the process-wide Worker
    domain, nor call its testing final_shutdown. Borrowed Worker/runner lifetime
    belongs to the caller. Runner.shutdown's unit return and Eio cancellation
    are never promoted to checked physical retirement. The caller keeps the
    Worker, switch and pump alive until [stopped]; release failures keep [stopping]. *)

(** Read authoritative coordination state and resource ledgers, without scanning
    mirror data. Recovering does not resurrect retired authority; it returns the
    actual phase/cleanup owner for this runtime's known logical lane. On process
    restart create a new runtime and restore from the existing catalog, wrapped
    keys, mirrors, durable outbox/import/upload/retirement records. Cursor/ticket/
    lease/observation/cancellation values never survive restart. Only network
    errors permit transport retries; other failures require explicit correction
    or a protocol-defined state transition, not an unchanged automatic retry. *)
val recover : runtime -> owner -> (packed_cursor, error) result

(** {1 Observation and helpers} *)

(** One immutable serial-owner read; graph cursors project their own resident
    state, never the visible graph by accident. Revoked scopes fault explicitly. *)
val observe : unit -> ('state, 'state, Core.state) t
val coordination : runtime -> Worker.coordination_snapshot
val owner : 'state cursor -> owner
val phase : 'state cursor -> 'state phase

(** Notifications are bounded invalidations, not retained full-state history.
    Register/sample atomically through the Worker. Callbacks run after state
    installation and must not yield/reenter execution. Overflow coalesces into
    a resample-required notification, never a lost durable acknowledgement.
    Observations retain registration/graph/query epochs; refresh and release
    operate on the original physical owner. A refreshed empty answer or missing
    item keeps the existing query's meaning; it is not a failed sync. *)
val watch_state
  : notify:(unit -> unit) -> (serving, serving, serving, observation, error) operation
val watch_query
  : id:Core.graph_id -> read:Read.packed_query -> notify:(epoch:int64 -> unit)
  -> (ready, ready, ready, observation * int64 * Read.answer, error) operation
val refresh_query
  : observation -> (ready, ready, ready, int64 * Read.answer, error) operation
val acknowledge_changes
  : Read.change_batch -> (ready, ready, ready, Read.change_ack, error) operation

(** Query observation creation/release races use the existing creator-finished,
    unallocated-release and finalization ledgers. The facade owns these calls;
    caller cancellation does not lose a subsequently allocated listener. Change
    ACKs match the original delivered windows and physically release those
    windows; an invalidation or newer presentation is not an ACK. *)
val error_message : error -> string
