# Logseq Overlay DB Package Implementation Plan

Goal: Add a standalone `logseq_overlay_db` package whose UUID-addressed logical database is computed from one durable authoritative Datascript database and one durable queryable outbox without retaining a second projected Datascript database or connection.

Architecture: `logseq_overlay_db` owns graph storage, the authoritative root, checkpoint, semantic outbox, query indexes over pending effects, logical snapshots, local mutation planning, authoritative rebase, and one merged logical change stream.
The UI and Worker consume only UUID-based read, mutation, and change contracts, while `logseq_sync` retains transport, encryption policy, retries, and server continuity policy.

Tech Stack: OCaml 5.1, Dune virtual libraries, Datascript OCaml, Eio, SQLite, Yojson, Transit, Digestif, Alcotest, and the existing Logseq graph storage format.

Related: This plan rejects the previously considered materialized `Projected_connection`, public `Entity_id`, and projected-Datascript-listener design, while retaining normalized UI, structure-interest, change-window, and row-local rendering goals.
It builds on [Extract Logseq Sync Package Boundary](../../implemented/architecture/2026-08-27-extract-logseq-sync-package-boundary.md), [Worker-Owned Managed Sync Orchestration](../../implemented/architecture/2026-08-28-worker-owned-managed-sync-orchestration.md), and [Pure Logseq DB Worker Reducer and Effect Runner](../../implemented/architecture/2026-08-31-pure-logseq-db-worker-reducer-effect-runner.md).

## Problem

The current `logseq_db_worker.Engine.t` owns a durable `Storage_session`, sync checkpoint, serialized outbox, and a second in-memory `projected_db`.

The projected database is rebuilt by replaying pending mutations over the authoritative database and is then used by the Worker read model.

This duplicates database ownership inside the Worker and makes raw Datascript values cross responsibilities that belong in a reusable graph data-plane package.

The current `logseq_sync` pure reducer also owns durable outbox records, their JSON codec, normalized transaction decoding, checksum calculation, and authoritative replan inputs containing raw `Datascript.db` values.

The Worker therefore depends on Sync to interpret its durable local database state, while Sync effects depend on the Worker to commit that state.

That split prevents a lower acyclic package from being the sole owner of authoritative storage, pending local intent, logical reads, and logical change classification.

The new design intentionally rejects a retained materialized projected database.

The logical projection is instead defined as:

~~~text
Projection(A, O) = apply active normalized outbox effects in durable sequence order over A
~~~

`A` is the durable authoritative Datascript database.

`O` is the durable semantic outbox together with queryable normalized effects and indexes whose size is proportional to the outbox, not to the authoritative graph.

There is no retained `P : Datascript.db`, no projected `Datascript.conn`, and no query-result cache representing the combined graph.

Every public read must nevertheless observe a single coherent logical database rather than separately reading whichever authoritative and outbox versions happen to be current.

The package must also make logical listening stronger than a raw union of authoritative and outbox notifications.

An authoritative transaction can be completely masked by a pending field patch.

An authoritative acknowledgement can add the same facts that an outbox removal removes.

A transport-only outbox state transition can change durable metadata without changing any UI-visible fact.

Publishing either underlying source event directly would therefore create duplicate notifications, false notifications, or observable intermediate states.

The current outliner planner assumes a concrete projected Datascript database.

Removing that database means mutation planning must consume the same logical overlay algebra as reads so a pending insert can immediately be edited, deleted, assigned task status, or given a child before synchronization.

The package must solve these semantics without leaking Datascript entity IDs, raw databases, raw transaction operations, or replace-all string outbox records through its public specification.

## Decision

### Apply the confirmed first-cutover decisions

The first cutover implements only the operations used by the current App and deletes every unused Worker protocol operation instead of recreating it in overlay.

The retained public read surface is graph information, journal listing, explicit page lookup, explicit block lookup, immediate children, and bounded page trees.

The retained local mutation surface is the closed `Save_block`, `Insert_blocks`, `Delete_blocks`, `Create_journal_page`, `Set_task_status`, and `Clear_task_status` ADT defined by overlay.

`Insert_blocks` exposes only the current App's append-to-parent shape, `Delete_blocks` exposes one selected subtree root, and `Create_journal_page` directly carries the journal day and supplied page UUID rather than nesting a generic page kind.

The current App's generic `Set_property` and `Remove_property` calls are translated during cutover into `Set_task_status` and `Clear_task_status`; neither public variant can carry an arbitrary property selector or property value.

Property, reference, tag, page-metadata, validation, move, and reorder reads may remain private composition inputs required to interpret authoritative data, but they are not additional first-cutover public operations or local mutation constructors.

Explicit block and page lookup DTOs may still return their authoritative kind, task, property, reference, tag, and page-metadata fields; current-App-only narrowing applies to request selectors and local-write capabilities, not to the completeness of a requested logical record.

E2EE uses opaque generation-bound preparation, protection, unprotection, and commit tokens, so Sync owns cryptographic execution without receiving raw durable records or database transactions.

The implementation is authorized to modify the canonical Sync and Worker specification `.mli` files required by the ownership cutover.

The implementation is also authorized to add the `logseq_overlay_db` virtual libraries and package metadata and to modify every necessary Dune and opam file of its direct dependents.

Subtree deletion freezes its UUID frontier and complete write footprint and never expands either after commit.

Remote-wins is defined by server causal order: a Queued path ends at its pre-submission resolution, an accepted Submitted path ends immediately before the own incorporation cursor, and a Stale-rejected path ends inclusively at the rejection cursor; only conflicts inside the applicable window cancel the complete optimistic delete.

Because the current hard-delete wire uses cascading `RetractEntity`, the exact singleton `t_before` conditional barrier and server-normalized transaction-log round-trip are implementation prerequisites; the first cutover does not attempt unsafe post-incorporation compensation.

### Make the logical database the package boundary

Create the independently installable `logseq_overlay_db` opam package.

Its concrete handle owns exactly one long-lived authoritative Datascript connection whose current root is `A`, plus one immutable queryable outbox root that is not a Datascript database.

This is the only long-lived Datascript connection and database lineage in memory.

The handle also owns the authoritative checkpoint, generation, projection revision, authoritative revision, logical-outbox revision, transport-outbox revision, storage lifecycle, graph ownership, execution lane, and logical change dispatcher.

Conceptually:

~~~text
logseq_overlay_db.Database.t
  |
  |-- Authoritative_store.t
  |     |-- one authoritative Datascript connection and current root
  |     `-- checkpoint and SQLite Storage_session
  |
  |-- Queryable_outbox.t
  |     |-- ordered semantic intents
  |     |-- normalized field and membership effects
  |     `-- indexes proportional to pending records
  |
  |-- revisions and one serialized execution lane
  `-- merged logical change dispatcher
~~~

The equation `Projection(A, O)` is the public database meaning.

It is not the name of an internal Datascript value.

The package installs one private `Datascript.listen` callback on the current authoritative connection plus one private listener on queryable-outbox transitions.

Those are source listeners for the merged logical change coordinator, not public notification streams.

Temporary immutable Datascript candidate roots may exist inside `Storage_session.stage_transact_batch` while staging an authoritative transaction or validating one Sync batch.

The package never creates a second candidate connection.

The staged root may be retained only by one opaque authoritative commit lease until commit or cancel and must never appear in a public snapshot, outbox record, listener payload, or long-lived `Database.t` field before commit.

Refactor `Storage_session` into a physical persister and stager rather than a second authoritative owner.

Restore returns the initial immutable Datascript root to `Authoritative_store`, and `Storage_session` retains only physical root addresses and counts, the durable tail, SQLite callbacks, allocation metadata, and lifecycle state after that handoff.

It must not retain a second set of EAVT, AEVT, or AVET `Persistent_sorted_set.t` handles alongside the authoritative Datascript root.

When tail compaction is required, staging restores short-lived lazy physical index handles from their root addresses, updates only paths touched by the bounded tail, stores new root addresses, and drops those handles before the staged lease is released.

Compaction reads schema, counters, and shared duplicate-datom metadata directly from the captured Datascript root and never calls graph-wide `Datascript.serializable` merely to rebuild storage metadata.

`stage_transact_batch` takes the package's captured authoritative root explicitly, applies sparse operations with pure `Datascript.with_tx` and `skip-store? = true`, and returns a staged root plus the physical SQLite batch.

Neither `Storage_session.t` nor any other long-lived package field retains a duplicate authoritative `Datascript.db` reference or second graph-index root set.

### Capture immutable logical snapshots

Expose an opaque, explicitly releasable `Database.snapshot` lease.

A snapshot pins exactly one immutable authoritative root, one immutable queryable outbox root, their internal source revisions, and one public snapshot version.

It contains no combined Datascript database and no memoized query result.

The lease owns the pinned roots only until `release_snapshot`, package close, or fatal invalidation.

Reads after release, close, or generation invalidation return a typed lifecycle error.

`release_snapshot` atomically prevents any new read from starting through that lease.

It waits for already-started reads to finish, or equivalently defers root clearing through an internal reference count until they finish, and only then drops the pinned roots.

The handle tracks active leases so close can invalidate them, clear their root references after already-running read calls finish, and then close storage without relying on caller garbage collection.

All reads for one public request use that captured pair.

This prevents a read from observing an old authoritative root with a new outbox or a new authoritative root with an old outbox.

Snapshot construction and listener registration share the package execution lane.

`listen` atomically registers a paused subscriber and returns a leased immediate predecessor snapshot for the first eligible event.

The Worker hydrates its initial interests from that lease, releases it, and then calls `activate_subscription` with its callback.

Events committed after registration remain ordered behind the subscriber cursor, and retention overflow before activation produces one resync rather than a subscribe/read gap.

### Use UUIDs at every public boundary

Use `Logseq_db_types.Graph_types.Uuid.t` for every block, page, mutation, scope, read selector, listener change, and precondition identity.

Datascript entity IDs remain an internal implementation detail of authoritative queries and authoritative transaction decoding.

They never appear in `logseq_overlay_db/spec`, Worker protocol v2, UI state, outbox semantics, cursor payloads, logs intended for replay, or widget keys.

Local transaction encoding should use `[block/uuid <uuid>]` lookup references where the wire format permits it.

Current protocol-native authoritative payloads may contain numeric entity references, but they enter the package only through the one opaque encoded-transaction ingress and are decoded internally against the staged authoritative root.

The package accepts no alternate legacy payload decoder or obsolete authoritative wire representation.

### Separate global ordering from target equality

Define a generation-scoped monotonic `projection_revision`.

Advance it exactly once when one committed operation changes at least one public logical read result.

Do not advance it for failed durability, an idempotent no-op, an equivalent authoritative acknowledgement, or a transport-only outbox transition.

Define independent authoritative, logical-outbox, and transport-outbox revisions for internal compare-and-set operations, but never expose the first two through public logical read metadata.

A transport-only state change advances the transport-outbox revision but not the logical-outbox or projection revision.

Define block, page, and scope state revisions as opaque equality tokens derived from canonical logical results rather than from the global projection revision.

The implementation may compute those tokens on demand as authenticated or collision-resistant digests.

It must not retain a second graph-sized map merely to cache every entity revision.

An unrelated graph transaction must not conflict with a valid target-local mutation.

### Make the outbox queryable

Replace the current `string list` public model with an opaque ordered outbox whose records contain:

- one UUID-addressed semantic mutation intent;
- the canonical mutation payload and fingerprint;
- a deterministic durable sequence;
- the normalized sync transaction payload;
- transport state;
- field-level logical effects;
- page and structure membership effects;
- tombstones; and
- reverse-dependency effects needed by public block snapshots; and
- bounded conditional dependency shadows for frozen Submitted or Accepted effects;
- bounded delete frontiers, complete write footprints, conflict guards, and rollback windows; and
- bounded server-order origin evidence retained through the compact receipt when a submitted delete is resolved by a causally-prior remote transaction.

Every semantic nondeterministic input used by replay, including generated UUIDs, client timestamps, and user-selected relative anchors, is fixed when the mutation is first accepted and is persisted in its semantic intent.

Derived order values, logical effects, and unsent Sync payloads are deterministic products of that intent and the current logical planning snapshot.

They may be recomputed while a record has never left `Queued`, but every submitted wire payload is frozen and every transport retry resends the identical mutation ID, fingerprint, `t_before`, and bytes. The deployed server does not deduplicate mutation IDs: an uncertain retry either executes against the still-current `t_before` or receives a batch-level `Stale` response after any prior or intervening execution advanced the cursor.

Ordinary submitted logical effects are also frozen; only a remote-conflicted delete may atomically deactivate its complete delete effect and terminate as `Remote_won Proven_unexecuted` when the exact conditional barrier itself proves non-execution.

The first `Queued -> Submitted` transition captures the minimal transitive owner closure required for the frozen effect to remain a valid graph, including destination parents, pages, property definitions, and their required memberships.

Each dependency shadow is a set of minimal required facts and predicates rather than a complete owner snapshot.

Its individual entity-existence, live-page, entity-kind, property-definition, schema-facet, parent-membership, page-membership, and anchor facts become visible only when the current authoritative projection no longer satisfies that exact frozen requirement.

An owner that still satisfies a required fact continues to expose every unrelated remote field update.

The support closure is part of outbox byte admission and submission fails before durability if it exceeds the configured bound.

Every delete frontier, footprint, guard, rollback window, and bounded origin-evidence allowance counts against durable outbox admission at `commit_local`.

There is no post-incorporation compensation budget: the protocol precondition below must prove that a delete whose guard has conflicted cannot execute.

If any artifact lacks a finite canonical bound, `Delete_blocks` is unsupported for that footprint and fails before publishing its local effect.

Restart and authoritative rebase must never reread the clock or generate a replacement UUID for an existing intent.

Use indexes such as the following:

| Index | Purpose |
| --- | --- |
| `by_mutation_id` | Idempotency, transport transitions, and acknowledgement lookup. |
| `records_by_sequence` | Deterministic composition and replan order. |
| `block_effects_by_uuid` | Point block hydration and field-level patches. |
| `page_effects_by_uuid` | Point page hydration and page-state changes. |
| `membership_by_parent_uuid` | Child insertion, deletion, move, and reorder. |
| `membership_by_page_uuid` | Page-tree membership changes. |
| `journal_index_effects` | Journal creation, rename metadata, recycle, restore, and removal. |
| `tombstones_by_uuid` | UUIDs hidden only while their owning delete effect remains active; rollback or terminal receipt removes every owned entry atomically. |
| `reverse_dependencies` | References, tags, properties, page metadata, and derived render fields. |
| `delete_guards_by_uuid` | Frozen delete footprint revisions and negative descendant, reference, auxiliary-fact, and page-lifecycle predicates. |
| `origin_evidence_by_cursor` | Validated own-submission intervals and exact simulated server-normalized datom multisets needed to distinguish remote conflicts from local incorporation independent of ACK/Pull order. |

Maintain a separate durable `mutation_receipts` index keyed by mutation ID.

Maintain a durable secondary `terminal_receipts_by_batch_id` index for bounded late `Accept_group` or `Reject_group` lookup after a Submitted delete has already compacted to `Remote_won` or equivalent `No_change`.

That secondary index lives in SQLite, is queried by exact opaque batch ID, and is not loaded as an in-memory receipt map or scanned from the mutation-ID ledger.

Its entry is created atomically with the primary receipt and has the same first-cutover lifetime: `collect_garbage` removes neither index, because late transport responses have no time bound and no generation-scoped no-ID-reuse epoch exists yet.

When an authoritative transition incorporates an ordinary accepted record, atomically replace the active outbox record with a compact receipt containing its fingerprint and generation-independent semantic outcome.

A Submitted remote-conflicted delete is the exception: the observed intervening cursor plus the exact `t_before` contract proves non-execution, so the same atomic transition deactivates the complete delete effect and creates a compact `Remote_won` receipt containing the bounded batch, semantic mutation fingerprint, and cursor evidence required to validate any late response.

A Queued conflict needs no shadow because it finalizes atomically as `Remote_won Before_submission` before any authoritative delete can exist.

The closed receipt outcome distinguishes `Applied`, `No_change`, `Remote_won`, and `Discarded` with its prior blocked reason rather than treating every historical mutation ID as successfully applied.

A Submitted delete resolved as equivalent authoritative `No_change` retains the same bounded original batch identity, `t_before`, operation tag, semantic mutation fingerprint, and cursor proof as a Submitted `Remote_won` receipt, so late acceptance or rejection can be validated without retaining its protected wire.

An active `Blocked_authoritative_mismatch` remains an inactive outbox diagnostic until explicit discard creates that discarded receipt.

Receipts never persist projection revision tokens.

Receipt lookup preserves same-ID idempotency across acknowledgement and restart without keeping inactive effects in the logical outbox or loading the receipt ledger into memory.

The first cutover does not garbage-collect mutation receipts because deleting them would weaken the documented idempotency contract.

A future receipt compaction design must introduce a generation-scoped no-ID-reuse boundary before it may change that rule.

The first-cutover `collect_garbage` operation therefore excludes mutation receipts and every `terminal_receipts_by_batch_id` entry.

One UUID may have effects from multiple pending mutations.

The indexes retain the ordered effect chain rather than only the latest record.

Normalized effects are field-level patches rather than complete block or page replacement snapshots.

If a local mutation changes only a block title, a later remote change to that block's properties remains visible through the logical overlay.

Conditional dependency shadows are not ordinary replacement patches.

They restore or override only each missing or mismatched required fact while the frozen dependent effect remains active, including removing a conflicting authoritative parent or page membership before exposing the required frozen membership.

For non-delete mutations, a remote move, recycle, entity-kind change, or property-schema change therefore cannot make a Submitted or Accepted overlay structurally invalid, while all unrelated authoritative fields remain visible and the full remote state reappears when the frozen effect resolves.

The remote-wins subtree-delete rule below is the deliberate exception: a conflicting authoritative transition deactivates the complete delete effect instead of shadowing the remote state.

`prepare_local` computes four bounded, UUID-addressed subtree-delete artifacts from its logical snapshot, and `commit_local` revalidates their complete read set and atomically freezes and persists them with the new Queued record before publishing any delete effect.

| Artifact | Required contents |
| --- | --- |
| `delete_frontier` | The exact block UUIDs that the semantic delete is allowed to retract. |
| `delete_write_footprint` | Every UUID-addressed entity, field, membership, reverse reference, comment-area fact, rewritten source title, timestamp, transaction-metadata fact, and default-property holder that the frozen wire may retract, replace, or touch. |
| `delete_conflict_guard` | The authoritative checkpoint captured by `commit_local`, revisions for the complete write footprint, and negative predicates for newly added or moved descendants, incoming references, auxiliary comment facts, and page-lifecycle changes. |
| `delete_rollback_window` | Every block UUID, page UUID, reverse render dependency, and old or new structure scope that must be compared when the complete optimistic delete effect is deactivated. |

The semantic delete set and protected wire payload never expand beyond the frozen `delete_frontier` and `delete_write_footprint`.

Preparation or commit fails before publishing the local delete when the frontier, footprint, guard, or rollback window exceeds the configured entity or byte admission bound, and first submission separately enforces the original protected wire bound before any send.

`Delete_blocks` is the deliberate exception to ordinary Queued replan.

Once `commit_local` freezes its artifacts, neither authoritative rebase nor submission may recapture, expand, or replace its frontier, footprint, guard, or rollback window; a changed guard invokes remote-wins instead.

The current hard-delete wire uses Datascript `RetractEntity`, which also retracts every incoming ref that exists when the transaction executes.

Consequently, a finite frozen footprint cannot safely compensate a stale delete after execution: a newly arrived descendant or incoming reference could have been retracted outside that footprint.

The first cutover therefore makes exact conditional server execution a hard prerequisite rather than attempting forward compensation.

Immediately before first submission, the package revalidates the frozen guard against its current authoritative checkpoint and records that checkpoint as the singleton batch's `t_before`.

The server must atomically execute that batch only when its current cursor equals `t_before`; any intervening transaction must produce a definitive non-executing rejection, and an accepted singleton owns the immediately following, non-interleaved cursor interval.

Implementation cannot enable `Delete_blocks` until the deployed-protocol integration gate proves this conditional barrier, contiguous own interval, batch-level Stale non-execution evidence, server-normalized Pull payloads, and lossless round-trip of the separate `outliner-op` field.

The package classifies authoritative origin by validated server-order evidence rather than by ACK, Pull, or callback arrival order.

Its private evidence combines the batch ID, mutation IDs, member ordinal/count, frozen `t_before`, acceptance interval when known, operation tag, semantic mutation fingerprint, and an exact simulation of each member against the authoritative root immediately before its expected cursor. Origin remains unresolved when neither transport evidence nor transaction semantics can bound the cursor window.

A validated singleton delete acknowledgement identifies its exact authoritative cursor, and a validated multi-member acknowledgement identifies one contiguous, non-interleaved cursor interval in member order.

Each decrypted authoritative transaction in an accepted own interval must have the expected cursor and the same normalized datom multiset as the frozen member simulated against that cursor's exact `db-before`; extra, missing, or changed facts fail Sync integrity. Datom list order is not identity because the deployed ClojureScript and OCaml Datascript implementations may emit the same transaction report in different orders.

The current Pull envelope does not echo `tx_id`; the deployed server uses the outer transaction `tx-id` only to report accepted-prefix and failed-member identities for a partially failed batch, and does not persist it in the transaction log or use it for deduplication. Pull returns the normalized transaction report plus a separate optional `outliner-op`, not the submitted client payload.

At the first continuous cursor after `t_before`, an exact simulated normalized datom match identifies the own transaction candidate. A semantically different occupied transaction proves that the frozen conditional batch could not execute at that `t_before`; after a batch-level `Stale` response, every cursor through the returned current cursor is proven remote to that submission.

Only when that first occupied cursor itself is a guard conflict may it terminate immediately as `Remote_won Proven_unexecuted`, because that transaction necessarily precedes the server's conditional rejection and later transactions cannot erase it.

If the first occupied cursor is unrelated or is an equivalent deletion, Sync holds that bounded Pull and every later ordinal as `Unresolved_delete_window` until `Tx_batch_ok` assigns the own cursor interval or a validated `Stale` rejection supplies the exact end of the non-execution window.

A later observed guard edit cannot terminate early because the server may already have rejected the delete before that edit, and an equivalent deletion cannot become `No_change` before the boundary because a later pre-boundary transaction may still be a conflict.

Held Pull data is bounded and may be discarded on restart because the durable checkpoint has not advanced; reconnect repulls it and may resend the exact frozen request. Such a retry is safe because the unchanged `t_before` either still permits the first execution or produces `Stale`; it is not mutation-ID deduplication.

A remote delete conflict is a transaction proven `Remote` whose logical change intersects the guard without already satisfying the complete delete intent.

Its cursor must be after the guard's captured checkpoint and causally before the attempted delete; under the exact `t_before` contract, that ordering proves the attempted delete did not execute.

The original delete and other transactions proven to belong to an own submission interval are not remote merely because their Pull arrives before their ACK.

Remote edits, moves, new or moved descendants, new incoming references, comment-area changes, default-property-holder changes, rewritten source-title changes, timestamp or transaction-metadata changes, and page-lifecycle changes inside that guard are conflicts.

Unrelated authoritative changes and an equivalent authoritative deletion are not conflicts.

Remote state wins every remote delete conflict.

For a never-submitted delete, the conflict transition removes the complete local delete effect, writes a durable `Remote_won Before_submission` receipt, blocks only transitively dependent Queued mutations, and emits at most one rollback projection event.

For a never-submitted delete, if a proven-Remote transition instead already satisfies the complete frozen delete intent, removing the optimistic effect is logically equivalent and writes a durable `No_change` receipt with no projection event.

For a Submitted delete whose held Pull is released by validated Stale rejection evidence, the authoritative catch-up transition applies the terminal priority below; a conflict outcome atomically deactivates the complete local delete effect and writes `Remote_won Proven_unexecuted`, retaining only bounded batch identity, `t_before`, rejection cursor, earliest conflict cursor, canonical conflict-kind set, and semantic mutation fingerprint in the compact receipt for late-response validation.

If a validated `Stale` rejection arrives first, its required server cursor atomically moves the delete to `Delete_barrier_rejected_pending_authoritative` instead of `Blocked`.

That durable state keeps the frozen logical delete effect active, sends no retry, and requires Sync to pull continuously through the rejection cursor.

At every caught-up transaction ordinal, the private durable state records the earliest intersecting conflict cursor and accumulates a canonical sorted non-empty set of closed conflict kinds for in-window evidence.

The kind set is finite and independent of decoded datom order, so one transaction that changes a frontier fact, adds a descendant, and adds an incoming ref produces the same receipt under every canonical transaction ordering.

Later transactions cannot erase that evidence even if they restore the guard's final values, and partial Pull plus restart preserves it.

When catch-up reaches the rejection cursor, the terminal priority is: any recorded conflict writes `Remote_won Proven_unexecuted`; otherwise a complete equivalent authoritative deletion writes `No_change`; otherwise the package deactivates the delete as `Blocked Stale_barrier` and requires a fresh mutation ID for any user retry.

That rejection cursor is the exact end of the conflict window.

If one Pull also contains later transactions, `apply_authoritative` resolves the delete against the intermediate root at that cursor, then processes every later ordinal as ordinary authoritative state; a later guard edit or move cannot flow backward into the rejected delete's outcome.

An `Invalid_t_before` rejection has no server cursor and is a malformed-request failure rather than this concurrency path.

The logical projection immediately becomes authoritative data plus the remaining active outbox, so every remote field, membership, descendant, and reference wins without a value-preimage cache or invented page-root promotion.

The rollback classifier seeds its bounded comparison with the complete frozen rollback window, every new guard entity, exact reverse render dependencies, and affected old and new page or structure scopes.

It emits `No_logical_change` when the canonical before and after results are equal, one exact logical change when they differ within the bound, or one resync sentinel if the candidate or dependency closure exceeds its bound.

The UI therefore refetches every interested affected fragment, including interested ref sources or metadata outside the visible subtree, while preserving all unrelated row identities.

The eventual rejection or exact unexecuted-suffix response is therefore an idempotent confirmation of the existing receipt and emits no second projection event.

An acknowledgement or authoritative incorporation for any original delete already proven unexecuted by Stale evidence, whether it terminated as `Remote_won`, equivalent `No_change`, or `Blocked Stale_barrier`, contradicts the required conditional barrier and enters fatal Sync integrity state.

The package never tries to repair this violation from the frozen footprint because `RetractEntity` may already have cascaded to out-of-footprint refs.

For a conflict-free accepted delete, `apply_authoritative` validates the transaction's exact touched facts against the frozen footprint before committing `Applied`.

That validation is sound because the exact barrier proves no intervening remote fact existed when `RetractEntity` executed; an out-of-footprint touch is a fatal integrity mismatch.

A proven-Remote transaction with a cursor after the accepted delete's own interval is not a pending delete conflict.

The transition first resolves the delete as ordinary `Applied`, releases its frozen delete artifacts, and then applies that later remote transaction as normal authoritative state in the same staged batch with at most one logical event.

If the later transaction recreates a deleted UUID, the recreated authoritative entity becomes normally visible.

A local mutation that depends on facts restored by deactivating a Submitted delete sees the terminal `Remote_won Proven_unexecuted` receipt in that same transition and follows ordinary dependency eligibility against the resulting logical state.

Remote-wins begins and ends only inside this server-ordered non-execution window.

After a conflict-free delete reaches `Applied`, later remote transactions follow normal authoritative semantics and do not retroactively retain its rollback artifacts.

The first cutover submits every user `Delete_blocks` as a singleton submission group so conditional rejection and acceptance barriers identify its outcome without cross-member ambiguity.

Use this lifecycle matrix:

| State | Logical effects | Payload rule | Legal next states |
| --- | --- | --- | --- |
| `Queued` | Ordinary effects are active and replannable, while a committed delete effect is active but its artifacts are frozen | No wire payload has been sent, so ordinary derived effects and payload may be recomputed deterministically; delete artifacts never recapture | `Submitted`, `Blocked`, durable `No_change`, or durable `Remote_won` receipt after rebase |
| `Submitted` | Active and frozen | The protected payload is immutable, and every timeout retry resends exactly the same bytes | `Submitted`, `Accepted_pending_authoritative`, `Delete_barrier_rejected_pending_authoritative` after a validated Stale response, direct durable `Remote_won Proven_unexecuted` once any causally-prior conflict is proven, durable `No_change` only after Stale boundary evidence proves an equivalent authoritative deletion with no earlier conflict, or `Blocked` after another definitive rejection |
| `Accepted_pending_authoritative` | Active and frozen | The server accepted the immutable submission batch, so its members are never replanned or retransmitted | Durable receipts, or `Blocked_authoritative_mismatch` for an ordinary terminal-requirement mismatch; a causally-prior remote delete conflict is fatal because it violates the conditional barrier |
| `Blocked` | Inactive | A never-submitted intent may be explicitly replanned, while a previously submitted rejection requires a new mutation ID | `Queued` through eligible `retry_blocked`, or durable discarded receipt through `discard_blocked` |
| `Delete_barrier_rejected_pending_authoritative` | The frozen delete effect remains active while private earliest-conflict evidence accumulates across authoritative catch-up | The rejected wire remains immutable and is not resent | Remain on duplicate rejection or partial catch-up, then prioritize `Remote_won Proven_unexecuted` when any conflict was observed, otherwise durable `No_change` for an equivalent authoritative deletion, otherwise `Blocked Stale_barrier`, or enter fatal integrity state on rejection-cursor or Pull continuity/checksum contradiction |

Every first submission persists a stable submission-batch ID, `t_before`, ordered member ordinal/count, and the exact frozen wire for each member.

The server's `Tx_batch_ok.t` becomes one acceptance barrier for that complete ordered group rather than an invented per-record cursor.

An accepted ordinary or conflict-free delete effect remains active until the package processes that barrier, or until a late acknowledgement proves the already-continuous checkpoint has passed it.

A `Blocked` record has no active logical effects.

Authoritative rebase replans only ordinary records that have never left `Queued`.

A committed Queued delete never recaptures its frozen artifacts; a matching guard change finalizes it through remote-wins.

It composes frozen `Submitted` and `Accepted_pending_authoritative` effects unchanged until a transport or authoritative transition resolves them, with the sole remote-wins exception that a proven causally-prior conflict atomically deactivates a Submitted subtree delete and writes its terminal non-execution receipt.

If deterministic replan proves a queued intent is now a semantic no-op because authoritative state already satisfies it, the same atomic authoritative transition removes the active record and writes a durable `No_change` receipt with its original fingerprint.

That resolution emits no projection event when removing the optimistic effect and applying the authoritative facts are logically equivalent.

When one queued record cannot be replanned, the package deterministically blocks only that record and transitively dependent records that are also still `Queued`, while independent later queued records continue deterministic replan.

Submission eligibility forbids a record from entering `Submitted` while any transitive dependency is still `Queued`, so a frozen record can never depend on a later-replannable predecessor.

If a previously submitted predecessor is definitively rejected, any already-Submitted or Accepted dependent remains active and byte-for-byte frozen with its own conditional dependency shadows until its own transport or authoritative outcome resolves it; cascading block alone never replans or deactivates a frozen record.

The only Submitted-dependent exception is a member that the server's validated partial-rejection partition explicitly places in the exact unexecuted suffix of its own submission group.

That proof is the member's own terminal transport outcome, so the rejection transition may deactivate it as `Blocked` when it depends transitively on the failed member, or retain its frozen bytes in the new retry group when it is independent.

All blocked queued intents remain durable for diagnostics and explicit user recovery.

### Define overlay reads once

Move authoritative Datascript projection and logical effect composition into one `Overlay_read` implementation.

`get_blocks` queries authoritative blocks by UUID, applies only indexed effects for the requested UUIDs, applies tombstones, and preserves request order.

Every present or missing point result carries its block or page state revision so a later mutation can form a target-local precondition.

`get_pages` follows the same semantics for explicit UUIDs.

`graph_info` returns graph identity, schema, generation-static capability and admission limits, and the logical snapshot version captured by the same lease, and it has no projected Datascript basis field.

Dynamic used capacity, protected-wire bytes, and retained delete-origin-evidence bytes belong to a separate `inspect_admission` administrative DTO.

They are not logical projection data, do not carry `snapshot_version`, and may change without advancing `projection_revision` or emitting a listener event.

`get_journals` traverses the indexed `block/journal-day` AVET range in descending order, merges active local journal creations, resolves equal dates by ascending UUID, and hydrates only the selected window. Candidate validation preserves page classification, including built-in exclusion and existing recycled-page handling. Inclusive date bounds apply before pagination.

Its typed result carries items and a projection- and date-range-bound date/UUID continuation, and Worker automatically registers `Journal_index_interest` when serving it. Journal collection revisions and offset cursors are removed; creation requires the target page revision. See [Indexed Journal Pagination](../bugfix/2026-09-07-indexed-journal-pagination.md).

Because journal cursors are fixed-snapshot cursors, a `Journal_index_interest` change restarts the affected list from its first window instead of appending through a stale cursor.

`get_structure` accepts a closed request variant for immediate children or a bounded-depth page tree, merges authoritative membership with the matching indexed delta, and then applies deterministic order and pagination.

Its result variant always carries the exact structure scope and scope revision, while block-tree members additionally carry depth and parent UUID.

A page-tree revision scope includes `maximum_depth`, so different viewport depths never share a precondition token.

The corresponding change interest omits depth and conservatively tells Worker to test every interested depth for that page UUID.

An empty parent still has a retained `Children_of` scope so the first local or remote child can be discovered.

Deleted explicit UUIDs return typed `Missing` values.

List queries omit missing members rather than inventing placeholder list entries.

Tombstones apply consistently to block hydration, page hydration, parent membership, page membership, and journal membership.

Authoritative moves and reorders affect the old and new parent scopes and the old and new page scopes in the same logical transition even though the first cutover exposes no corresponding local mutation operation.

Block projection includes current refs, tags, properties, task state, and page-derived render fields.

The logical change classifier therefore expands direct transaction candidates through exact reverse dependencies before comparing canonical before and after results.

If the dependency closure exceeds the configured item or byte budget, return `Projection_resync_required` rather than truncating an exact UUID list.

The Worker handles that sentinel by rehydrating only its current UUID and structure interests.

### Merge authoritative and outbox listening by commit

The package obtains authoritative source facts from its private `Datascript.listen` callback and outbox source facts from its private queryable-outbox transition listener.

Each source fact is internal and carries the same package commit identifier plus before and after source revisions.

Every authoritative source fact also carries its zero-based batch ordinal and total transaction count, with those fields and `skip-store? = true` attached to each sparse `transact_conn` metadata value and the package commit identifier attached to the staged outbox transition.

The authoritative listener resolves changed internal entity IDs against its before and after roots into block UUIDs, page UUIDs, and direct structure scopes before the IDs leave `Authoritative_store`.

The transition coordinator waits for the complete logical transition and never exposes either source fact directly.

Each prepared transition records the exact number of authoritative fragments plus whether an outbox fragment is expected, so an outbox-only commit never waits for a nonexistent Datascript report and a multi-transaction batch cannot publish after only its first report.

For one transition it performs:

~~~text
capture immutable (A_before, O_before)
  -> collect the exact direct candidate UUIDs and scopes
  -> stage each ordered authoritative transaction from A_before through Storage_session
  -> prepare staged A_after, O_after, and all normalized indexes
  -> expand the bounded dependency closure
  -> compare Projection(A_before, O_before) with Projection(A_after, O_after)
  -> prepare zero or one immutable logical event and reserve its dispatcher slot
  -> durably commit authoritative data, checkpoint, outbox, and receipts
  -> replay each same sparse transaction on the sole conn with commit ID, ordinal/count, and skip-store metadata
  -> collect all private Datascript reports and the staged outbox source fragment by commit ID
  -> verify every report against its corresponding staged report with bounded sparse invariants
  -> publish the staged outbox root, revisions, and prepared event
~~~

One authoritative ordinal may intersect multiple delete guards, including one Submitted singleton and multiple later Queued deletes.

The transition resolves every guard independently, atomically commits every resulting `Remote_won`, `No_change`, or blocked outcome, unions and canonically deduplicates overlapping rollback windows, and still emits zero or one exact or resync event; failure while staging any member leaves all guards and receipts unchanged.

The durable commit is the linearization point.

Snapshot capture is excluded by the same lane from staging through post-commit connection publication.

Each connection transaction uses Datascript's existing `skip-store?` transaction metadata, so it preserves the authoritative batch's Datascript transaction boundaries and produces one sparse listener report without performing a Datascript storage write.

If persistence fails before commit, the connection remains on `A_before` and the handle publishes no roots, revisions, or events.

After durability, the only operations allowed to allocate or fail are the already-validated ordered sparse `transact_conn` calls required to drive `Datascript.listen` and advance the sole live connection.

Equivalence checks compare ordinal/count metadata, exact canonical sparse `tx_data`, tempid resolution, max entity and transaction counters, schema identity, and point results for only the affected lookup refs and datoms.

They must not call `Datascript.db_hash`, `Datascript.diff`, scan an index, or otherwise turn publication into graph-sized work.

An unexpected post-commit transaction or equivalence failure enters fatal state and reopens from SQLite with a fresh generation before serving another snapshot.

This failure path never calls `reset_conn` and therefore never constructs a graph-sized synthetic transaction report.

All classification, replan, allocation, and validation that can fail occurs before it.

Before durability, the coordinator reserves capacity in a bounded revision-ordered dispatcher journal and constructs the complete immutable event payload.

If capacity is temporarily unavailable, the transition applies backpressure or returns a typed busy result before durability.

After the post-commit sparse connection transaction and equivalence check succeed, only non-allocating outbox-root, revision, and pre-reserved-event publication is permitted.

An unexpected failure after durability places the handle in a typed fatal state and requires reopen from the durable authoritative root plus outbox.

That reopen uses a fresh generation, which forces Worker and UI rehydration even when the committed event was never published.

One logical transition emits at most one event and advances the projection revision at most once.

An authoritative field change masked by an outbox patch emits no event.

An authoritative update to an unmasked field emits one event.

An authoritative acknowledgement that replaces an equivalent optimistic effect emits no event.

A transport-only outbox transition emits no event.

Deactivating a blocked effect feeds its exact affected UUIDs and scopes into the canonical before-and-after comparison, which emits zero or one exact event, or the explicit bounded resync sentinel when classification exceeds its limit.

Callbacks run outside the database lane in revision order.

Each subscriber advances an independent cursor over the bounded dispatcher journal.

A subscriber that falls behind retention is atomically advanced to one coalesced `Projection_resync_required` notification, so slow callbacks cannot create unbounded memory or block unrelated subscribers forever.

A callback exception is isolated from the commit and from other subscribers.

`unlisten` is idempotent and atomically marks the subscription inactive so no new callback can begin afterward.

A non-reentrant `unlisten` waits for an already-running callback to finish, while `unlisten` called by its own callback suppresses all future delivery without waiting on itself or deadlocking.

Activating an already-unlistened subscription returns a typed lifecycle error.

The package does not replay listener history after reopen.

Every reopen creates a new generation.

The Worker treats a generation change as a mandatory interested-state bootstrap, discards old change-window cursors, and only then resumes incremental delivery.

`logseq_db_worker` gains a v2 protocol that owns cumulative unacknowledged change windows, projection-bound pull cursors, ACK, retention limits, generation reset, and latest-wins Worker push behavior.

The current v1 `Graph_invalidated` contract is deleted rather than treated as an existing change-window implementation.

### Make local writes atomic over the logical view

Replace planners that require a concrete projected Datascript database with planners over a private logical `Graph_view` interface.

The private interface supports UUID-addressed block, page, structure, property, reference, and validation reads against one logical snapshot only as required to plan the confirmed App mutation subset and compose its returned records.

It does not enlarge the public read or mutation surface.

A local mutation can therefore target a block or parent created by an earlier pending mutation.

Delete the complete legacy `Logseq_db_types.Mutation` interface after the coordinated caller cutover, including `Mutation.context`, `expected_basis`, every generic nested mutation type and codec, and `Mutation.success`.

The replacement semantic mutation identity is derived only from `Types.local_mutation`'s stable mutation UUID and closed semantic payload, while logical commit status and before and after projection revisions are returned as `Logseq_overlay_db.Types.local_commit`.

The Worker protocol request envelope carries only the block, page, and structure-scope revisions observed by the UI separately from the mutation identity.

`prepare_local` first canonical-validates the semantic mutation, computes its fingerprint, and checks active outbox records plus durable receipts by mutation ID before it checks caller preconditions.

The same fingerprint for an active logically applied record or any durable `Applied` or `No_change` receipt returns `Existing_applied` with status `Already_applied` and before and after revisions both set to the current generation's projection revision.

The same fingerprint for a terminal `Remote_won` receipt returns `Existing_remote_won` and does not claim that the delete is applied.

The same fingerprint for an inactive blocked record returns `Existing_blocked`, and a discarded receipt returns `Existing_discarded`; neither result claims that the mutation is applied.

A different fingerprint always returns a typed identity conflict.

This ordering makes an exact duplicate idempotent even when the original target revision in its request envelope became stale after the first commit.

Only for a fresh mutation ID does `prepare_local` derive the required caller-observed precondition coverage from the mutation kind and return `Missing_precondition` when the UI omitted a revision for state that it claims to have observed.

A block save requires the target block revision.

Block insertion requires the observed destination parent and destination structure-scope revisions; generated child UUID nonexistence, private anchors, and planner validation facts are captured internally.

Block deletion requires the selected root revision and the relevant parent or page-tree scopes observed by the UI; the exact frozen descendant frontier, negative descendant dependency, complete write footprint, reverse dependencies, and every unobserved structural fact are internal planner dependencies.

Journal creation requires the intended journal page's explicit `Missing` page-state revision; journal-index uniqueness and private page metadata are captured internally rather than forcing an unrelated journal-list read.

`Set_task_status` and `Clear_task_status` require only the target block revision from the UI.

The fixed status property definition, its schema, and any other planner-only dependency are read through the private logical `Graph_view`, captured by `prepare_local`, and revalidated by `commit_local`; they do not require a public property-definition read API.

No precondition contract is created for unused move, reorder, indent, outdent, ordinary page-management, schema-management, or generic property-management operations because their public constructors are deleted in the first cutover.

The specification freezes the complete per-constructor table separating caller-observed preconditions from internally captured planner dependencies, including missing-target revisions, so a caller cannot accidentally obtain weaker concurrency semantics by supplying a partial set and does not need to fetch private planning state.

For that fresh ID, `prepare_local` validates the mutation against one logical snapshot, checks the local expectations, derives deterministic semantic intent, captures every additional planner dependency revision, records the complete logical planner read set, and produces normalized effects.

The prepared handle is opaque, generation-bound, one-shot, explicitly cancelable, and tied to the captured logical read-set revisions rather than to whole authoritative or outbox revisions.

`commit_local` reacquires the execution lane and revalidates the captured block, page, scope, and planner-dependency revisions before any durability.

Before that read-set validation, it repeats the mutation-ID and fingerprint lookup against the current active outbox plus receipt store while holding the lane.

If another prepared commit already consumed the ID, the same fingerprint returns the exact current `Existing_applied`, `Existing_remote_won`, `Existing_blocked`, or `Existing_discarded` outcome and a different fingerprint returns identity conflict, with no second sequence, record, receipt, or event.

If unrelated authoritative data or transport metadata changed while every planner dependency is equal, it appends the mutation at the current durable sequence without reporting a conflict.

If a relevant dependency changed, it returns a typed local conflict and consumes no mutation ID or durable sequence.

It then atomically persists the new canonical outbox root and any receipt metadata through the existing SQLite batch boundary.

An initially valid mutation whose canonical result is `No_change` writes a durable `No_change` receipt without creating an active outbox record or projection event.

The authoritative database remains unchanged.

A Capture-created block therefore becomes immediately readable from the durable outbox overlay and is written into the authoritative database only when a later authoritative Sync batch incorporates it.

After commit, the package publishes the already-prepared immutable outbox root and logical event.

E2EE protection occurs when Sync prepares the first `Queued -> Submitted` transition, not while the local capture is being committed.

Persistence failure changes neither the authoritative root, outbox root, logical reads, projection revision, nor listener stream.

### Expose typed sync capabilities

Move durable outbox codec ownership, normalized transaction encoding and decoding, authoritative checksum calculation, and remaining-intent replan into `logseq_overlay_db`.

Keep authentication, WebSocket lifecycle, E2EE key custody, encryption and decryption execution, retry policy, submission batching policy, and server continuity policy in `logseq_sync`.

Use one opaque preparation followed by one final application so Sync can request encryption or decryption without receiving a raw database, durable outbox record, or Datascript transaction operation.

The public crypto bridge exposes only bounded correlation IDs and opaque protocol bytes through request accessors.

The owning snapshot, outbox, or authoritative operation requires the originating request and rejects missing, extra, duplicate, reordered, stale, or oversized results before decoding, staging, or persistence.

`inspect_sync` returns a pure DTO containing a sync compare-and-set token, checkpoint, and typed submission descriptors, and it never pins authoritative or outbox roots.

For a first submission, Sync selects an ordered non-empty descriptor group within its policy limits and calls one `begin_outbox_transition (Submit_group mutation_ids)`.

The package requires every `Delete_blocks` descriptor to be selected alone in a singleton group.

Before returning one correlated protection request for the complete group, the package revalidates that every member is Queued, all transitive dependencies are submission-eligible, the member count is bounded, and the total plaintext size fits the request-side limit.

Because protected bytes do not exist yet, `begin_outbox_transition` cannot validate their size.

After Sync supplies the exact correlated request and protected values, `apply_outbox_transition` validates each protected value and the complete protected group against `wire_batch_max_bytes`, then performs the atomic transition; an oversized result is a typed workflow error and no durable transition occurs.

One atomic commit assigns the stable submission-batch ID, captures `t_before` from the expected Sync token, persists member ordinal/count plus every immutable protected wire, and moves the complete group `Queued -> Submitted` before returning the ordered bounded wire list that Sync sends as one `Tx_batch`.

A timeout retry addresses the submission-batch ID, retains every active member as `Submitted`, and returns the identical ordered group, original `t_before`, and protected bytes rather than moving any record back to a replannable state. The server either executes it if the conditional cursor is still current or rejects the complete request as `Stale`; repeated `tx-id` values alone provide no idempotency.

Once Stale evidence proves a delete unexecuted and resolves it as `Remote_won Proven_unexecuted`, equivalent `No_change`, or `Blocked Stale_barrier`, the active group no longer retries.

If a first-cursor conflict created the `Remote_won` receipt before the unlabelled server response, its authoritative commit returns `Retain_terminal_owner_until_response batch_id`; Sync keeps the connection-scoped `Terminal_awaiting_response` owner solely to correlate the next ACK or rejection and never resends the batch.

A late rejection is idempotent, a late acceptance for any such proven-unexecuted outcome is a fatal conditional-barrier contradiction, and closing that WebSocket epoch clears the transport owner because no unlabelled response from that connection can arrive afterward.

For an ordinary or conflict-free group, an acknowledgement whose barrier is ahead of the current checkpoint commits every member of that exact Submitted group to `Accepted_pending_authoritative` and does not remove their active effects.

If the acknowledgement barrier equals the current checkpoint, the same transition compares the group's combined terminal frozen requirements with the current authoritative target, creates `Applied` receipts for ordinary incorporated members, and creates `Blocked_authoritative_mismatch` for any unmet final requirement without exposing an intermediate state.

If a late acknowledgement barrier is below the current continuous, checksum-validated checkpoint, the acknowledgement itself proves ordinary group incorporation and creates `Applied` receipts even when later authoritative transactions have since overwritten the targets.

A delete already resolved from Stale non-execution evidence never takes either ordinary `Applied` shortcut, regardless of whether its semantic outcome is `Remote_won`, `No_change`, or `Blocked Stale_barrier`; acknowledgement or own incorporation is a fatal conditional-barrier violation.

A definitive ordinary member rejection eventually commits that failed member to `Blocked`, emits its rollback within the group transition, and requires a new mutation ID for any semantically changed retry.

A validated `Stale` rejection of an unresolved Submitted delete must include its server cursor and enters `Delete_barrier_rejected_pending_authoritative` without changing the logical projection; Sync then pulls continuously through that cursor, validates the resulting `Pull_ok` cursor and checksum, and only then lets overlay resolve the frozen guard to `Remote_won Proven_unexecuted`, equivalent authoritative `No_change`, or `Blocked Stale_barrier`.

Another definitive delete rejection follows the ordinary inactive `Blocked` path; if a matching `Remote_won Proven_unexecuted` receipt already exists, any late rejection only confirms that receipt and emits no event.

Sync normalizes `Tx_reject` into a closed reason-specific resolution.

The current protocol's `Stale` branch carries only its required server cursor; it does not invent a rejection checksum, and subsequent `Pull_ok` continuity plus checksum validation follows the normal authoritative-batch path.

The operational-failure branch carries only the checksum, accepted IDs, failed ID, missing UUIDs, and diagnostics permitted by that reason and validates any exact accepted-prefix, zero-or-one failed-member, and unexecuted-suffix partition.

Overlay rejects duplicate, reordered, missing, foreign, or non-prefix IDs and requires a valid acceptance barrier whenever the accepted prefix is non-empty.

The rejection dispatcher first routes a singleton original delete through its dedicated Stale catch-up or terminal conflict rule above.

For an ordinary group only, one atomic rejection transition moves the accepted prefix to `Accepted_pending_authoritative` or receipts when its barrier is already covered, moves the failed member plus any transitively dependent members that the validated partition places in that exact unexecuted suffix to inactive `Blocked`, and forms a new frozen retry group from only independent members of that same unexecuted suffix with their original protected member bytes.

This is an own-outcome exception for exact unexecuted members, not a cascading-block rule for Submitted or Accepted dependents in another group; every other frozen dependent remains active until its own transport or authoritative outcome resolves it.

The retry group's envelope may capture the new `t_before`, batch ID, ordinal, and count, but no semantic effect, operation tag, mutation ID, or protected transaction byte may change.

The complete partition produces at most one logical change summary and one listener event.

`begin_authoritative` takes the database handle, expected sync token, and a bounded protocol-neutral encoded batch, captures the required roots inside a generation-bound preparation handle, and returns any unprotection request.

After Sync decrypts the request items, `apply_authoritative` validates the correlated results, decodes canonical transactions internally, stages and atomically persists the authoritative candidate, updates the checkpoint, converts incorporated accepted records into durable receipts, resolves Submitted and rejection-first delete outcomes, and replans only never-submitted ordinary queued intents in sequence.

If a cursor expected by a still-Submitted delete cannot yet be classified by exact simulated transaction semantics and ACK or Stale rejection has not bounded that window, `apply_authoritative` consumes the preparation and returns `Authoritative_deferred (Await_submission_outcome batch_id)` without a durable authoritative transition.

Sync retains only the original bounded opaque `Types.authoritative_batch`, never the decoded values, and retries `begin_authoritative` with the new Sync token after committing the requested transport outcome; restart simply repulls from the unchanged durable checkpoint.

For every accepted submission group whose barrier occurs inside an authoritative batch, `apply_authoritative` evaluates the intermediate staged root immediately after that barrier transaction rather than only the final batch root.

For every active delete guard, it also evaluates each authoritative transaction ordinal, classifies only proven-Remote changes by server cursor order, conditional-barrier evidence, and exact simulated normalized datoms, resolves a conflicting Queued or Submitted delete as `Remote_won`, resolves a complete equivalent remote deletion as `No_change`, completes rejection-first catch-up, and validates an incorporated conflict-free own delete's actual touched facts against its frozen footprint.

If one staged Pull contains own delete incorporation followed by a later remote transaction, it resolves the delete at the own ordinal and applies the later transaction normally, with no intermediate public snapshot and at most one logical event for the complete batch.

It compares the combined terminal frozen requirements in member order, so an earlier same-field member superseded by a later member in the same acknowledged group is still incorporated rather than falsely mismatched.

If an ordinary member's final required state is not present at the barrier, the transition creates an inactive `Blocked_authoritative_mismatch` diagnostic instead of its success receipt and drops that frozen effect and dependency shadows in the same logical transition.

Delete members use their dedicated conflict-resolution and conditional-barrier integrity rules instead of this ordinary blocked path.

A later authoritative transaction after an ordinary conflict-free receipt may overwrite its target without changing that already-earned receipt.

A Pull-first Submitted conflict reaches its terminal `Remote_won Proven_unexecuted` receipt in the authoritative transition whose occupied cursor proves non-execution; only rejection-first ordering retains the still-active frozen delete until continuous catch-up reaches the rejection cursor.

`apply_authoritative` compare-and-sets the authoritative, logical-outbox, and transport-outbox revisions captured by the preparation and atomically persists the authoritative database, checkpoint, active outbox, and receipts.

Outbox and authoritative preparations own only in-memory state and need no cancel operation; abandoning them leaves ordinary unreachable memory. Snapshot activation remains explicitly cancelable because it owns staging files.

The Worker effect runner holds an opaque preparation only across the bounded crypto effect and final application.

The unavoidable authoritative wire ingress is represented by an opaque size-validated `encoded_transaction` with explicit `of_string` and `to_string` functions.

This input-only wire boundary does not expose decoded Datascript operations or durable outbox encoding.

Authoritative application, acknowledgement, receipt creation, blocked suffix formation, and logical notification are one transition.

No caller supplies a projected database or `projection_transactions` list.

### Own graph storage lifecycle

Move exclusive graph ownership, mirror inspection, snapshot activation, authoritative restore, checkpoint restore, outbox restore, index reconstruction, garbage collection, and close sequencing into the package.

Expose typed constructors for package dependencies, attachment metadata, mirror locations, and snapshot artifacts.

Expose public `inspect_mirror`, bounded E2EE-aware snapshot activation, `delete_mirror`, and `collect_garbage` operations while keeping filesystem operations, SQLite handles, and snapshot parsing private.

`mirror_inspection` and every attachment derived from it carry an opaque mirror generation captured while inspecting the package-owned location.

`open_` first acquires exclusive graph ownership and then revalidates that generation, graph UUID, and checkpoint before opening storage; a stale inspection or attachment returns a typed error rather than opening the wrong replacement mirror.

Snapshot activation accepts only a captured `Absent` inspection and returns typed `Mirror_exists` for `Available`, so ordinary bootstrap can never overwrite authoritative data or a pending outbox.

Replacing a mirror requires an explicit generation-checked `delete_mirror`, a new `Absent` inspection, and then activation; there is no implicit replace or force flag.

Activation stages into a private temporary mirror and compare-and-sets the captured absent generation at commit, while delete and garbage collection compare-and-set their captured inspection generation, so a concurrent activation, delete, or replacement cannot be overwritten through a time-of-check/time-of-use race.

Encrypted snapshot activation is a bounded loop rather than one graph-sized crypto request.

`prepare_snapshot_activation` creates a generation-bound activation lease, `next_snapshot_unprotection_batch` returns at most one `wire_batch_max_bytes` request, and `supply_snapshot_unprotection_batch` validates and consumes exactly that request before the next batch may be requested.

The private parser streams ciphertext from the artifact and stages each validated plaintext chunk without retaining the complete ciphertext or plaintext collection.

Only after `next_snapshot_unprotection_batch` reports completion may `finish_snapshot_activation` create the commit lease.

Cancellation, malformed correlation, crypto failure, or stale mirror generation closes temporary files, deletes the incomplete staging mirror, releases request buffers, and leaves the active mirror unchanged.

`open_` restores and validates the authoritative database and outbox, rebuilds only outbox-sized indexes, computes the current logical revision state, and publishes no startup change.

`open_` receives an `Eio.Switch.t` whose lifetime encloses the database handle and uses package-owned fibers beneath it for dispatcher delivery and independent subscriber callbacks.

Immediately after acquiring graph ownership, `open_` registers an idempotent switch-release hook that drives the same close state machine, so exception or cancellation of the enclosing switch cannot strand SQLite handles, temporary files, subscribers, or the ownership lock when the caller omitted explicit `close`.

The ownership acquisition also installs a synchronous partial-open cleanup guard before the next fallible operation.

Every `Error` or exception from generation revalidation, SQLite open, authoritative restore, outbox or receipt decode, index reconstruction, listener installation, or fiber startup runs that same idempotent cleanup before `open_` returns, leaving the later switch hook as a no-op.

The caller may therefore repair the mirror and retry inspect, attachment, and open inside the still-live outer switch without an ownership conflict from the failed attempt.

Explicit close racing switch release performs cleanup exactly once, and every later operation observes the same closed error.

The database execution lane serializes snapshot-lease capture, local commit, outbox transitions, authoritative preparation capture and commit, listener registration, mirror lifecycle operations, garbage collection, and close.

Long logical queries run on active leased immutable snapshots outside the short handle-state mutex.

Close prevents new leases and preparations, invalidates every outstanding lease and prepared handle, waits for already-running reads and commits, unregisters internal listeners, drains committed notifications or converts lagging subscribers to terminal resync, cancels and joins its dispatcher fibers, clears all package-held root references, and closes `Storage_session` last.

### Enforce an acyclic package graph

Use this project dependency direction:

~~~text
logseq_db_types
        |
        v
logseq_db_storage
        |
        v
logseq_overlay_db
        |        \
        v         v
logseq_sync ---> logseq_db_worker ---> logseq_journal app
~~~

`logseq_overlay_db` depends on neither `logseq_sync` nor `logseq_db_worker`.

`logseq_db_storage` remains lower-level and depends on neither overlay nor sync policy.

`logseq_sync` depends on the overlay public specification but never holds a database handle directly in pure policy state.

The Worker effect runner is the composition owner that translates Sync effects into typed overlay calls.

The app continues to depend only on the Worker protocol and never imports `logseq_overlay_db`.

### Add canonical specification interfaces

Create one public virtual library with two canonical virtual modules:

~~~text
logseq_overlay_db/
  spec/
    dune
    types.mli
    database.mli
~~~

The intended public module paths are:

~~~ocaml
Logseq_overlay_db.Types
Logseq_overlay_db.Database
~~~

`types.mli` contains only stable UUID-based values, revisions, snapshots, changes, transitions, results, and closed errors.

`database.mli` contains opaque handles and public lifecycle, read, listen, local-write, outbox, and authoritative APIs.

Neither interface may mention `Datascript.db`, `Datascript.conn`, `Datascript.entity_id`, `Datascript.tx_op`, `Logseq_sync_*`, `Logseq_db_worker_*`, or a raw `string list` outbox.

The canonical `types.mli` must define:

- opaque generation, projection, authoritative, logical-outbox, transport-outbox, block-state, page-state, and scope revisions;
- `equal`, `compare`, `to_string`, and version-validating `of_string` operations for every revision that crosses the Worker protocol;
- a public snapshot version containing only generation and projection revision, while authoritative, logical-outbox, and transport-outbox revisions remain internal to the separate Sync compare-and-set token;
- a logical `graph_info` containing graph identity, name, schema, generation-static capability and admission limits, and snapshot version, with no Datascript basis;
- a separate administrative `admission_inspection` containing dynamic used capacity and retained origin-evidence bytes, with no logical snapshot version;
- explicit `Present` and `Missing` block and page lookup results carrying their UUID-local state revision;
- a typed journal-list result carrying journals with page revisions and a date/UUID next cursor;
- UUID-only structure revision scopes for exact query preconditions and broader structure interests for change delivery;
- a closed `structure_request` ADT for immediate children and bounded-depth page trees, while the journal index uses its dedicated typed list result and explicit pages use UUID point lookup;
- matching structure-result variants whose members cannot confuse block depth and parent data with journal page data;
- a scope revision in every structure result used as a mutation precondition;
- exact projection changes carrying generation plus adjacent before and after projection revisions, UUIDs, and structure scopes;
- an explicit `Projection_resync_required` change that carries the new generation and revision;
- one bounded logical-change summary shared by commit results, with `No_logical_change`, exact UUID and interest sets, or `Logical_resync_required` rather than truncated lists;
- typed non-negative server cursors, checksums, bounded protocol-neutral encoded transactions with explicit codecs, and a pure authoritative-defer directive that exposes only the awaited submission-batch identity;
- typed outbox states, submission descriptors, bounded transport-output DTOs, legal transport transitions, terminal transport dispositions, blocked recovery operations, and compact mutation receipts;
- closed delete-conflict kinds, remote-won receipt reasons, and `Delete_barrier_rejected_pending_authoritative` outbox state that expose no rollback window or transaction facts;
- typed mirror presence and snapshot activation metadata without public storage paths;
- stable local, outbox, authoritative, snapshot-activation, and deletion commit result records with every field required by Worker or Sync;
- one closed current-App `local_mutation` ADT with no generic page, property, schema, move, reorder, or insertion-position payload;
- a closed local-commit outcome that distinguishes a newly committed result from an existing mutation outcome discovered by the commit-time identity recheck;
- target-local and planner-read-set precondition conflicts; and
- separate closed errors for construction, lifecycle, reads, listening, local prepare, local commit, blocked recovery, admission inspection, crypto conversion, outbox prepare, outbox commit, authoritative input, authoritative prepare, authoritative commit, mirror inspection, snapshot activation, deletion, and garbage collection.

The critical closed request and change shapes are conceptually:

~~~ocaml
type task_status =
  | Todo
  | Doing
  | In_review
  | Now
  | Done
  | Canceled
  | Backlog
  | Waiting
  | Later

type block_tree =
  { uuid : Graph.block_uuid
  ; title : string
  ; children : block_tree list
  }

type local_mutation =
  | Save_block of
      { mutation_id : Graph.Uuid.t
      ; block : Graph.block_uuid
      ; title : string
      }
  | Insert_blocks of
      { mutation_id : Graph.Uuid.t
      ; tree : block_tree
      ; parent : Graph.Uuid.t
      }
  | Delete_blocks of
      { mutation_id : Graph.Uuid.t
      ; root : Graph.block_uuid
      }
  | Create_journal_page of
      { mutation_id : Graph.Uuid.t
      ; page : Graph.page_uuid
      ; title : string
      ; journal_day : int
      }
  | Set_task_status of
      { mutation_id : Graph.Uuid.t
      ; block : Graph.block_uuid
      ; status : task_status
      }
  | Clear_task_status of
      { mutation_id : Graph.Uuid.t
      ; block : Graph.block_uuid
      }

type structure_revision_scope =
  | Children_revision of Graph.block_uuid
  | Page_tree_revision of
      { page : Graph.page_uuid
      ; maximum_depth : int
      }

type structure_interest =
  | Children_interest of Graph.block_uuid
  | Page_tree_interest of Graph.page_uuid
  | Journal_index_interest

type structure_request =
  | Children of
      { parent : Graph.block_uuid
      ; limit : int
      ; cursor : Graph.Cursor.t option
      }
  | Page_tree of
      { page : Graph.page_uuid
      ; maximum_depth : int
      ; limit : int
      ; cursor : Graph.Cursor.t option
      }

type projection_change =
  | Exact of
      { generation : generation
      ; before_revision : projection_revision
      ; after_revision : projection_revision
      ; block_uuids : Graph.block_uuid list
      ; page_uuids : Graph.page_uuid list
      ; structure_interests : structure_interest list
      }
  | Projection_resync_required of
      { generation : generation
      ; after_revision : projection_revision
      ; reason : resync_reason
      }

type logical_change_summary =
  | No_logical_change
  | Exact_logical_change of
      { block_uuids : Graph.block_uuid list
      ; page_uuids : Graph.page_uuid list
      ; structure_interests : structure_interest list
      }
  | Logical_resync_required of resync_reason

type existing_mutation =
  | Existing_applied of local_commit
  | Existing_remote_won of remote_won_receipt
  | Existing_blocked of blocked_mutation
  | Existing_discarded of blocked_discard_commit
~~~

Every cross-process revision module has the same `equal`, `compare`, `to_string`, and version-validating `of_string` surface.

`server_cursor`, `checksum`, and `encoded_transaction` have validating constructors and bounded codecs.

`authoritative_transaction` combines one typed server cursor with one encoded transaction.

`authoritative_batch` validates strict cursor ordering, the through cursor, optional checksum, transaction count, and total encoded bytes before returning an opaque batch.

Structure read results carry a `structure_revision_scope`, while projection changes carry broader `structure_interest` values that can be produced without knowing subscriber depth.

The Worker matches a page-tree change by page UUID against every currently interested depth and refetches each matching request with its own revision scope.

The initially accepted `database.mli` surface is preserved below as decision history. It was subsequently superseded by the durable-mirror lifecycle collapse and the workflow-wrapper collapse; the current canonical contract is `logseq_overlay_db/spec/database.mli`.

It refers directly to the sibling `Types` module and must not alias the wrapped `Logseq_overlay_db` module from inside the same library.

~~~ocaml
module Graph = Logseq_db_types.Graph_types

type t
type snapshot
type subscription
type limits
type dependencies
type attachment
type mirror_location
type mirror_inspection
type snapshot_artifact
type prepared_snapshot_activation
type prepared_snapshot_commit
type write_precondition
type prepared_local
type local_preparation =
  | Prepared_local of prepared_local
  | Existing_mutation of Types.existing_mutation
type protection_request
type protected_values
type unprotection_request
type decrypted_values
type prepared_outbox_transition
type prepared_outbox_commit
type authoritative_preparation
type prepared_authoritative_commit
type authoritative_finish =
  | Authoritative_prepared of prepared_authoritative_commit
  | Authoritative_deferred of Types.authoritative_defer

val limits
  :  response_budget_bytes:int
  -> outbox_max_records:int
  -> outbox_max_bytes:int
  -> change_max_items:int
  -> change_max_bytes:int
  -> dispatcher_capacity:int
  -> wire_batch_max_bytes:int
  -> (limits, Types.limits_error) result

val dependencies
  :  epoch_ms:(unit -> int64)
  -> monotonic_ns:(unit -> int64)
  -> limits:limits
  -> (dependencies, Types.dependencies_error) result

val mirror_location
  :  application_support_directory:string
  -> graph_id:Graph.Uuid.t
  -> (mirror_location, Types.mirror_error) result

val snapshot_artifact
  :  path:string
  -> applied_server_cursor:Types.server_cursor
  -> expected_checksum:Types.checksum option
  -> expected_rows:int
  -> (snapshot_artifact, Types.snapshot_input_error) result

val inspect_mirror
  :  dependencies
  -> mirror_location
  -> (mirror_inspection, Types.mirror_error) result

val mirror_presence : mirror_inspection -> Types.mirror_presence

val attachment
  :  mirror_inspection
  -> graph_name:string
  -> (attachment, Types.attachment_error) result

val prepare_snapshot_activation
  :  dependencies
  -> mirror_inspection
  -> artifact:snapshot_artifact
  -> (prepared_snapshot_activation, Types.snapshot_prepare_error) result

val next_snapshot_unprotection_batch
  :  prepared_snapshot_activation
  -> (unprotection_request option, Types.snapshot_prepare_error) result

val supply_snapshot_unprotection_batch
  :  prepared_snapshot_activation
  -> decrypted_values
  -> (unit, Types.snapshot_prepare_error) result

val finish_snapshot_activation
  :  prepared_snapshot_activation
  -> (prepared_snapshot_commit, Types.snapshot_prepare_error) result

val commit_snapshot_activation
  :  prepared_snapshot_commit
  -> (Types.snapshot_activation_commit * mirror_inspection,
      Types.snapshot_commit_error) result

val cancel_snapshot_activation : prepared_snapshot_activation -> unit
val cancel_snapshot_commit : prepared_snapshot_commit -> unit

val delete_mirror
  :  dependencies
  -> mirror_inspection
  -> (Types.mirror_delete, Types.mirror_delete_error) result

val collect_garbage
  :  dependencies
  -> mirror_inspection
  -> (Types.garbage_collection, Types.garbage_collection_error) result

val open_
  :  sw:Eio.Switch.t
  -> dependencies
  -> attachment
  -> (t, Types.open_error) result
val close : t -> (unit, Types.close_error) result

val current_snapshot : t -> (snapshot, Types.read_error) result
val snapshot_version : snapshot -> Types.snapshot_version
val release_snapshot : snapshot -> unit

val graph_info : snapshot -> (Types.graph_info, Types.read_error) result

val inspect_admission
  :  t
  -> (Types.admission_inspection, Types.admission_inspection_error) result

val get_blocks
  :  snapshot
  -> Graph.block_uuid list
  -> (Types.block_lookup list, Types.read_error) result

val get_pages
  :  snapshot
  -> Graph.page_uuid list
  -> (Types.page_lookup list, Types.read_error) result

val get_journals
  :  snapshot
  -> from_day:int
  -> through_day:int
  -> limit:int
  -> cursor:Graph.Cursor.t option
  -> (Types.journal_list_result, Types.read_error) result

val get_structure
  :  snapshot
  -> Types.structure_request
  -> (Types.structure_result, Types.read_error) result

val listen
  :  t
  -> (subscription * snapshot, Types.listen_error) result

val activate_subscription
  :  subscription
  -> notify:(Types.projection_change -> unit)
  -> (unit, Types.listen_error) result

val unlisten : subscription -> unit

val write_precondition
  :  blocks:(Graph.block_uuid * Types.block_state_revision) list
  -> pages:(Graph.page_uuid * Types.page_state_revision) list
  -> scopes:(Types.structure_revision_scope * Types.scope_revision) list
  -> (write_precondition, Types.precondition_error) result

val prepare_local
  :  t
  -> expected:write_precondition
  -> Types.local_mutation
  -> (local_preparation, Types.local_prepare_error) result

val commit_local
  :  t
  -> prepared_local
  -> (Types.local_commit_outcome, Types.local_commit_error) result

val cancel_local : prepared_local -> unit

val retry_blocked
  :  t
  -> expected:write_precondition
  -> mutation_id:Graph.Uuid.t
  -> (Types.local_commit, Types.blocked_retry_error) result

val discard_blocked
  :  t
  -> mutation_id:Graph.Uuid.t
  -> (Types.blocked_discard_commit, Types.blocked_discard_error) result

val protection_plaintexts
  :  protection_request
  -> (Types.crypto_item_id * string) list

val protected_values
  :  request:protection_request
  -> encrypted:(Types.crypto_item_id * string) list
  -> (protected_values, Types.crypto_result_error) result

val unprotection_ciphertexts
  :  unprotection_request
  -> (Types.crypto_item_id * string) list

val decrypted_values
  :  request:unprotection_request
  -> plaintexts:(Types.crypto_item_id * string) list
  -> (decrypted_values, Types.crypto_result_error) result

val inspect_sync : t -> (Types.sync_view, Types.sync_read_error) result

val begin_outbox_transition
  :  t
  -> expected:Types.sync_token
  -> Types.outbox_transition
  -> (prepared_outbox_transition * protection_request option,
      Types.outbox_prepare_error) result

val finish_outbox_transition
  :  prepared_outbox_transition
  -> protected_values:protected_values option
  -> (prepared_outbox_commit, Types.outbox_prepare_error) result

val commit_outbox_transition
  :  t
  -> prepared_outbox_commit
  -> (Types.outbox_commit, Types.outbox_commit_error) result

val cancel_outbox_transition : prepared_outbox_transition -> unit
val cancel_outbox_commit : prepared_outbox_commit -> unit

val begin_authoritative
  :  t
  -> expected:Types.sync_token
  -> Types.authoritative_batch
  -> (authoritative_preparation * unprotection_request option,
      Types.authoritative_prepare_error) result

val finish_authoritative
  :  authoritative_preparation
  -> decrypted_values:decrypted_values option
  -> (authoritative_finish, Types.authoritative_prepare_error) result

val commit_authoritative
  :  t
  -> prepared_authoritative_commit
  -> (Types.authoritative_commit, Types.authoritative_commit_error) result

val cancel_authoritative : authoritative_preparation -> unit
val cancel_authoritative_commit : prepared_authoritative_commit -> unit
~~~

`Types.local_commit` exposes mutation ID, `Applied`, `No_change`, or `Already_applied` status, one bounded `logical_change_summary`, generation, and before and after projection revisions.

`Types.local_mutation` is owned by overlay and contains exactly the six conceptual variants above.

It does not reuse `Logseq_db_types.Mutation.t`, `create_page_kind`, `property_selector`, `property_value`, or a generic insertion-position type; the final cutover deletes those generic mutation interfaces after their last caller moves.

`Types.local_commit_outcome` is `Local_committed` of `local_commit` or `Local_existing` of `existing_mutation` so a commit-time race never has to mislabel a remote-won, blocked, or discarded ID as applied.

For a receipt replay, both revisions are the current revision and no listener event is emitted.

`Types.delete_conflict_kind` is closed and distinguishes `Frontier_fact_changed`, `Descendant_closure_changed`, `Incoming_reference_changed`, `Auxiliary_write_footprint_changed` with comment-area, default-property-holder, rewritten-source-title, timestamp, or transaction-metadata category, and `Page_lifecycle_changed`.

`Types.delete_conflict_kind_set` is a canonical sorted non-empty set over that finite ADT, never an order-sensitive decoded-datom list.

`Types.remote_won_reason` is the closed `Before_submission` or `Proven_unexecuted` outcome.

`Types.remote_won_receipt` exposes the original mutation identity, one `remote_won_reason`, the canonical conflict-kind set, and a bounded opaque proof summary sufficient to validate late transport responses without exposing the rollback window, wire bytes, or transaction facts.

`Types.blocked_mutation` exposes the stable mutation ID, fingerprint, prior transport state, closed block reason, and whether a same-ID retry is eligible without exposing the stored intent encoding.

`Types.blocked_discard_commit` exposes the mutation ID, durable discarded outcome, generation, equal current before and after projection revisions, and `No_logical_change` because entering `Blocked` already removed the effect and emitted any required rollback.

`Types.sync_view` is a pure immutable value with accessors for its token, checkpoint, and submission descriptors.

`Types.authoritative_defer` is the closed `Await_submission_outcome` of an opaque submission-batch ID; it exposes neither decoded transaction data nor a preparation handle.

`Types.terminal_transport_disposition` is the closed `No_transport_owner`, `Clear_transport_owner`, or `Retain_terminal_owner_until_response` of one opaque submission-batch ID.

The retained branch means Sync enters a bounded connection-scoped `Terminal_awaiting_response` state with retry disabled; overlay has already removed the logical effect and compacted the durable record.

`mirror_inspection` is a package-owned `Available` or `Absent` result whose available branch can produce an attachment without exposing or reconstructing graph-directory and database-path policy.

`Types.snapshot_activation_commit` exposes the activated graph UUID, checkpoint, checksum, and mirror generation, while the paired inspection provides the package-owned attachment path.

Each submission descriptor exposes its mutation ID, fingerprint, state, dependency eligibility, attempt metadata, and plaintext or protected byte length needed for bounded grouping, but not its durable outbox encoding or decoded Datascript operations.

Its closed state payload includes `Delete_barrier_rejected_pending_authoritative of { through : server_cursor }`; that descriptor is explicitly `Must_pull` and not retry-eligible, so `inspect_sync` gives Sync every public value required to resume catch-up after restart without private imports.

`Types.submission_wire` is a distinct bounded output DTO with accessors for mutation ID, typed outliner-operation tag, opaque protected transaction bytes, and byte length.

It is not the input-only `encoded_transaction` type and cannot be decoded into a durable outbox record through the public API.

`Types.submission_batch` exposes its opaque batch ID, captured `t_before`, member ordinal/count consistency, ordered non-empty `submission_wire` list, and total byte length.

The closed outbox transition ADT includes `Submit_group` of an ordered mutation-ID list, `Retry_group` of a batch ID, `Accept_group` of batch ID and acceptance barrier, and `Reject_group of { batch_id : submission_batch_id; resolution : rejection_resolution }`.

Sync attaches its connection-scoped current owner batch ID to every otherwise-unlabelled rejection before calling overlay; overlay resolves the exact active group or `terminal_receipts_by_batch_id` entry and rejects a missing, foreign, or state-incompatible batch ID without guessing from outbox order.

That rejection resolution distinguishes a partial accepted-prefix, failed-member, and unexecuted-suffix partition from `Stale of { through : server_cursor }` and other definitive reasons, so a cursor-bearing Stale delete cannot be mistaken for an ordinary failed member.

`Submit_group` rejects a user delete combined with any other member because every delete is a singleton group in the first cutover.

`Types.outbox_commit` exposes generation, before and after projection revisions, the new sync token, committed transition, activity state, one bounded logical-change summary, and zero or one complete `submission_batch` for a first submission, exact retry, or independent suffix retry after partial rejection.

Sync constructs exactly one transport `Tx_batch` from that DTO's `t_before` and ordered wires by mapping them to `{ tx_id; outliner_op; tx }`.

Every timeout retry returns the same batch ID, `t_before`, member order, mutation IDs, operation tags, and protected bytes bit-for-bit.

`Types.authoritative_commit` exposes generation, before and after projection revisions, the new checkpoint and sync token, bounded `terminal_receipts` covering incorporated `Applied`, equivalent authoritative `No_change`, and `Remote_won` outcomes together with each terminal transport disposition, replanned queued IDs, blocked IDs, and one bounded logical-change summary.

Sync clears an owner only for `Clear_transport_owner` or a closed WebSocket epoch; it retains the batch identity for `Retain_terminal_owner_until_response`, so an unlabelled late `Tx_batch_ok` can still be converted to `Accept_group batch_id` and checked for a fatal contradiction.

Every commit operation that can affect the open logical database uses the common `{ generation; before_projection_revision; after_projection_revision; logical_change_summary }` envelope, and a no-change result has equal revisions.

`No_logical_change` emits no listener event.

An exact commit summary plus its common generation and adjacent revisions maps field-for-field to one `Exact` event and is never truncated.

A resync summary maps its reason, generation, and after revision to `Projection_resync_required`; the commit result retains its own before revision, while a subscriber-overflow resync intentionally has no single adjacent before revision.

`snapshot_artifact` and `Types.authoritative_batch` have validated constructors that enforce size, cursor, checksum, and canonical wire-ingress bounds before any preparation handle is created.

Snapshot leases, local preparations, outbox preparations, authoritative preparations, and final commit tokens are generation-bound linear capabilities whose cancel or release operation deterministically drops pinned roots and rejects later use.

`prepared_snapshot_activation` is instead a mirror-generation-bound linear state machine that permits only `next -> supply -> next ... -> finish`.

Double-next, supply-before-next, finish-before end-of-file, response reuse, and any call after cancel return closed typed state errors, while each individual crypto request, response, and final snapshot commit token remains one-shot.

The final `types.mli` must define every referenced result and error before implementation starts.

The specification task must resolve those shapes completely rather than leaving ellipses or implementation-defined exceptions in the canonical interface.

### Add the package implementation and tests

Create this package tree:

~~~text
logseq_overlay_db/
  spec/
    dune
    types.mli
    database.mli
  lib/
    dune
    types.ml
    database.ml
    authoritative_store.ml
    authoritative_store.mli
    logical_snapshot.ml
    logical_snapshot.mli
    overlay_effect.ml
    overlay_effect.mli
    queryable_outbox.ml
    queryable_outbox.mli
    mutation_receipt.ml
    mutation_receipt.mli
    delete_conflict.ml
    delete_conflict.mli
    crypto_bridge.ml
    crypto_bridge.mli
    overlay_read.ml
    overlay_read.mli
    overlay_planner.ml
    overlay_planner.mli
    logical_change.ml
    logical_change.mli
    transition.ml
    transition.mli
    change_dispatcher.ml
    change_dispatcher.mli
    query_cursor.ml
    query_cursor.mli
    sync_tx_codec.ml
    sync_tx_codec.mli
    authoritative_checksum.ml
    authoritative_checksum.mli
    ownership.ml
    ownership.mli
    mirror.ml
    mirror.mli
    snapshot_parser.ml
    snapshot_parser.mli
    outliner_order.ml
    outliner_order.mli
    outliner/
      planner_contract.ml
      planner_contract.mli
      graph_read.ml
      graph_read.mli
      tree.ml
      tree.mli
      validation.ml
      validation.mli
      references.ml
      references.mli
      save_block.ml
      save_block.mli
      insert_blocks.ml
      insert_blocks.mli
      delete_blocks.ml
      delete_blocks.mli
      create_journal_page.ml
      create_journal_page.mli
      task_status.ml
      task_status.mli
  test/
    dune
    test_support.ml
    naive_projection_oracle.ml
    test_overlay_reads.ml
    test_overlay_mutations.ml
    test_overlay_changes.ml
    test_overlay_sync.ml
    test_overlay_storage.ml
    test_overlay_concurrency.ml
    test_performance.ml
    fixtures/
      performance/
        100000-blocks-v1.manifest.json
  tool/
    dune
    fixture_generator.ml
    fixture_generator.mli
    performance_benchmark.ml
    test_performance.sh
~~~

The test-only `naive_projection_oracle.ml` may materialize a small complete projection for differential testing.

It must never be linked into the production package.

Add `logseq_overlay_db.opam` and `logseq_overlay_db.opam.locked` at the repository root.

Add a `logseq_overlay_db` package stanza to `dune-project`.

The package's direct project dependencies are `logseq_db_types` and `logseq_db_storage`.

The virtual public library depends only on `logseq_db_types` and Eio for its explicit switch lifetime, while storage and Datascript remain implementation-only dependencies.

The implementation may depend on Datascript, Eio, Digestif, Transit, SQLite, Unicode libraries, and Yojson.

Alcotest is test-only.

The virtual `logseq_overlay_db` library contains only `Types` and `Database`, and its default implementation is `logseq_overlay_db.impl`.

All other implementation modules are private.

### Move data-plane modules without compatibility aliases

Use this ownership migration:

| Current path | New owner or outcome |
| --- | --- |
| `logseq_db_worker/lib/engine.ml` and `.mli` | Split into overlay `Database`, `Transition`, `Authoritative_store`, and outbox modules, then delete. |
| `logseq_db_worker/lib/read_model.ml` and `.mli` | Rewrite into authoritative projection plus `Overlay_read`, then delete old paths. |
| `logseq_db_worker/lib/query.ml` and `.mli` | Move only cursor behavior required by the confirmed App reads to overlay `Query_cursor`, then delete every unused Worker query branch and protocol constant. |
| `logseq_db_worker/lib/mutation_plan.ml` and `.mli` | Rewrite only the confirmed App mutation subset as overlay `Overlay_planner`, then delete the old all-operation planner. |
| `logseq_db_worker/lib/outliner_order.ml` and `.mli` | Move only the ordering primitives required by App block insertion and deletion, then delete the old module. |
| `logseq_db_worker/lib/outliner/` | Move only closed `Save_block`, append-to-parent `Insert_blocks`, single-root `Delete_blocks`, direct `Create_journal_page`, `Set_task_status`, and `Clear_task_status` behavior through logical `Graph_view`; delete every unused planner branch without an overlay replacement. |
| `logseq_db_worker/lib/ownership.ml` and `.mli` | Move to overlay lifecycle ownership. |
| `logseq_db_worker/lib/synced_mirror.ml` and `.mli` | Move to overlay `Mirror`. |
| `logseq_db_worker/lib/synced_snapshot_parser.ml` and `.mli` | Move to overlay `Snapshot_parser`. |
| `logseq_sync/lib/pure_reducer/checksum.ml` and `.mli` | Move to overlay `Authoritative_checksum`. |
| `logseq_sync/lib/pure_reducer/pure_tx.ml` | Move to overlay `Sync_tx_codec`. |
| Sync Core outbox codec and local transaction encoding | Move to overlay outbox and sync codec modules. |
| `logseq_db_types/lib/mutation.ml` and `.mli` | Replace final App and Worker callers with the six closed Worker-v2/overlay mutation shapes, then delete the generic mutation ADT and codec without an alias. |
| Worker effect runner | Retain as the sole adapter between Worker, Sync, and overlay public APIs. |
| Worker pure reducer and protocol | Retain lifecycle, request routing, and public wire ownership, then replace v1 invalidation with v2 change-window and ACK semantics. |
| `logseq_db_storage/` | Retain as the lower durable storage implementation. |

Delete `logseq_db_worker.engine` after every caller uses `Logseq_overlay_db.Database`.

Delete `authoritative_database`, `projected_database`, `restore_managed_projection`, `prepared_mutation_database`, `prepared_mutation_operations`, raw `managed_outbox_records`, and caller-built `projection_transactions`.

Do not leave forwarding modules, deprecated aliases, dual codecs, dual outbox writes, or fallback reads.

## Testing Plan

All production behavior is verified through the public `Logseq_overlay_db.Database` interface, real Datascript roots, real SQLite `Storage_session` fixtures, and deterministic Eio concurrency barriers.

The deterministic 100,000-block seed builder is test infrastructure and may write the lower storage fixture directly before production overlay behavior exists, but every measured read, write, transition, and listener assertion opens and exercises that fixture only through the public overlay interface.

Tests do not assert record field layout or merely prove that the specification types compile.

The test-only naive oracle sequentially replays small semantic histories into a temporary Datascript value and compares every public read with the optimized logical overlay.

That oracle is correctness evidence only and is forbidden from production libraries.

| Suite | Required behavior |
| --- | --- |
| Snapshot and read | Empty outbox equals authoritative state, graph info and journal listing use the same snapshot, one lease pins one A/O/revision tuple, UUID batch order and missing results are exact, concurrent updates never tear block and structure reads, release racing an already-started read preserves its roots until that read returns, and reads started after release or close fail with the exact lifecycle error. |
| Block overlay | Local insert, field-level edit, multiple ordered edits, pending insert followed by edit, remote unmasked fields, and remote masked fields. |
| Journal and explicit pages | Journal creation, deterministic journal ordering, an unknown authoritative journal inserted before a paginated window triggers `Journal_index_interest` and first-window refetch, authoritative ordinary/class/property page metadata remains readable by explicit UUID point lookup without a public ordering API, and equivalent acknowledgement creates no duplicate journal. |
| Structure | Local first-child insertion into an empty parent, before and after insertion, pending-created parent, deletion, and exact old/new scopes, plus authoritative same-parent reorder, cross-parent move, and cross-page move without corresponding public local mutation constructors. |
| Tombstone | Explicit missing result, membership removal, subtree hiding, rejection rollback, and remote-wins deactivation of the entire frozen delete effect with zero or one projection event according to canonical before and after equality and no descendant promotion. |
| Delete conflict rollback | Queued conflict sends no wire and deactivates the complete delete without recapturing its artifacts; Submitted conflict covers ACK-before-Pull, Pull-before-ACK, Pull-before-rejection, rejection-before-Pull, split Pull, restart during Stale catch-up, change-then-restore, conflict-then-equivalent-delete, equivalent-delete-at-`B+1` followed by conflict-at-`B+2` with rejection-through-`B+2`, unrelated-at-`B+1` followed by guard-edit-at-`B+2` with rejection-through-`B+1`, and same-Pull transactions after the rejection cursor, plus remote edit, move, new descendant, new incoming ref, comment-area, default-property-holder, rewritten-source-title, timestamp, transaction-metadata, and page-lifecycle paths; only a conflict at the first occupied cursor may terminate before the rejection boundary, earliest in-window conflict evidence survives partial catch-up, a post-boundary edit never changes the delete outcome, conflict-then-equivalent produces `Remote_won` plus `No_logical_change`, a pre-outcome timeout retry is byte-identical, terminal `Remote_won` never resends, an equivalent remote deletion with no earlier conflict yields `No_change`, a Stale catch-up with neither conflict nor satisfied intent yields `Blocked Stale_barrier`, a causally-prior remote transaction plus delete acceptance or incorporation fails integrity, a conflict-free incorporated `RetractEntity` touches only the frozen footprint, remote-after-own-delete resolves the delete first and then applies normally without a Missing flash, and the deployed integration gate proves stale `t_before` cannot execute. |
| Delete conflict determinism | One remote ordinal that hits frontier, descendant, incoming-ref, and auxiliary categories produces one canonical sorted non-empty kind set independent of decoded datom order; split batches and restart preserve the same earliest cursor and set; multiple overlapping guards resolve independently but atomically, and their rollback windows union and deduplicate before the single logical comparison. |
| Local planning | The six closed current-App variants plan against logical pending state, reject every constructor-specific missing caller-observed precondition, internally capture status-definition and other planner-only dependencies, remove global expected-basis behavior, record the exact internal read set, tolerate unrelated authoritative and transport changes, and produce deterministic semantic intent plus normalized effects; source-boundary tests reject generic page kinds, property selectors or values, multi-position insertion, and every unused constructor only in mutation/write-request shapes while allowing complete read-only block and page DTO fields. |
| Listening | Durability precedes notification, masked remote changes leave public graph-info snapshot version unchanged and produce no event, equivalent acknowledgement produces no event, unmasked remote fields and journal-index membership changes produce one event, and transport-only transitions produce no event. |
| Merged transition | Authoritative update plus acknowledgement and outbox removal exposes no intermediate state and emits zero or one event with one revision advancement; one ordinal intersecting multiple Queued guards or one Submitted plus later Queued guards resolves all outcomes atomically, handles conflict for one and equivalent intent for another, unions and deduplicates overlapping rollback windows, and leaves every guard unchanged if any staging step fails. |
| Acknowledgement ordering | ACK before Pull, Pull before ACK, rejection before Pull, Pull before rejection, split Pull batches, and one Pull containing both sides of a barrier produce identical origin classification and final logical results for the same server cursor history; rejection-first state exposes its required catch-up cursor and survives restart, ACK exactly at checkpoint validates combined ordered terminal requirements, ACK after a later overwrite uses continuous checkpoint evidence, missing state at the barrier blocks only unmet ordinary members, same-field members in one group are not falsely mismatched, and every outcome survives restart. |
| Submission group | Multi-member protection and `Queued -> Submitted` commit atomically or leave every member Queued, timeout retry returns an identical complete batch, over-limit and dependency-ineligible groups fail before durability, user deletes reject non-singleton selection, every acceptance or rejection carries the connection-scoped batch ID, foreign or mismatched batch IDs fail without changing state, duplicate late responses use exact active-or-terminal batch lookup, partial rejection validates the exact partition, accepted prefix remains active, failed and dependent unexecuted members roll back once, independent suffix bytes enter one new frozen retry group, a Stale-rejected delete is not automatically resent, and restart preserves every group relation. |
| Terminal transport owner | Pull-first `Remote_won` retains the unlabelled response correlation as `Terminal_awaiting_response` with retry disabled, late rejection confirms and clears it, late ACK fails the conditional-barrier invariant, socket-epoch close clears it, rejection-bounded `No_change` and other response-already-seen outcomes return `Clear_transport_owner`, and no path loses the batch ID before consuming or making the unlabelled response impossible. |
| Server concurrency invariant | A deployed-protocol integration test proves that `Tx_batch.t_before` is an exact conditional barrier, an accepted effectful group owns one contiguous non-interleaved cursor interval in member order, retrying the frozen request at its old cursor yields batch-level `Stale` rather than mutation-ID deduplication, Pull stores server-normalized transaction reports without `tx-id` and preserves the separate `outliner-op`, a delete accepted before a conflicting remote transaction has the lower cursor, and a stale delete receives a definitive batch-level non-executing rejection with a catch-up cursor; deterministic tests reject own-interval normalized-datom or touched-footprint mismatch and never infer origin from message arrival order alone. |
| Rebase | Disjoint remote change, same-field local override, different-field merge, moved or deleted anchor, owner-present but required parent/page membership changed, page recycled, property definition or schema facet changed, edits to a frozen delete footprint, a new or moved remote descendant, equivalent remote deletion, Queued `Remote_won Before_submission`, `Delete_barrier_rejected_pending_authoritative`, Submitted `Remote_won Proven_unexecuted`, Accepted causally-prior conflict integrity failure, no descendant promotion, exact rollback window, remote-after-own-delete ordering, remote authoritative reorder in each ordinary outbox state, frozen non-delete submitted and accepted payloads, queued-only ordinary replan, no-op intent receipt, blocked dependent record, restart, and state-aware dependent handling. |
| Idempotency | Same mutation ID and fingerprint bypasses stale request preconditions and returns current-generation `Already_applied` for a logically active outcome or every durable `Applied` or `No_change` receipt, including local no-op, Queued equivalent, and Submitted equivalent cases before and after restart and `collect_garbage`; it returns `Existing_remote_won`, `Existing_blocked`, or `Existing_discarded` for those exact outcomes, returns a typed conflict for a different payload without another durable record, and resolves late Accept or Reject by exact batch ID without scanning the receipt ledger. |
| Restart | Pending Capture is readable after reopen, logical snapshots match before and after restart, startup emits no fake change, and corrupt or non-canonical outbox fails closed. |
| Concurrency | Two prepared local writes with the same fresh ID and fingerprint create only one durable outcome and zero or one event even when the winner is `No_change`, the loser returns `Local_existing`, a different fingerprint conflicts, an intervening block or discard returns its exact Existing outcome, unrelated local and authoritative competition remains target-local, a Submitted transition during local preparation is non-conflicting, reads do not tear, explicit close racing switch cancellation cleans up exactly once, exceptional switch exit releases ownership so the same graph can reopen, close invalidates retained leases and waits for in-flight reads, and no callback occurs after close. |
| Failure atomicity | Planning, delete-artifact admission, conflict rollback derivation, staging, SQLite, checkpoint, and outbox failures leave reads, revisions, and listeners unchanged, a conditional-barrier contradiction enters fatal Sync integrity state, and an impossible post-commit publication enters fatal state. |
| Listener lifecycle | Paused subscribe plus predecessor lease and explicit activation has no gap or hydration race, revisions are ordered, pre-activation overflow resyncs, callback exceptions are isolated, callbacks can safely start reads, idempotent external unlisten waits for an in-flight callback, callback-self-unlisten never deadlocks, no callback starts after unlisten, a full dispatcher reserves before commit, slow subscribers coalesce to resync, concurrent commits cannot overtake, and close handles backlog deterministically. |
| Crash recovery | A forced failure after SQLite commit but before event publication causes fatal reopen with a fresh generation, Worker discards old windows, and interested UI state is rehydrated. |
| Crypto bridge | Protection and unprotection correlate exact request items and reject missing, extra, duplicate, reordered, stale, canceled, or cross-generation results; a large encrypted snapshot advances through bounded one-at-a-time batches and releases every completed batch before requesting the next. |
| Mirror lifecycle | Resolve, encrypted snapshot activation, activation failure, existing mirror with pending outbox preservation, explicit generation-checked delete-before-replace, garbage collection, ownership conflict, stale inspection, concurrent activation/delete generation races, failed open synchronously releases partial ownership and resources so the same live switch can retry, and reopen all use only typed public lifecycle APIs. |
| Worker and UI locality | An uninterested UUID and interest window performs no hydration and changes no row model, a one-block intersection hydrates only that UUID and replaces only its normalized block fragment, a journal-index or structure-only change refetches only matching registered queries, and a remote-wins rollback covers the frozen footprint, new guard entities, reverse dependents, and affected page or structure scopes so interested external ref sources, titles, metadata, comments, and property-holder fragments refresh too; unrelated row identities and revisions remain equal, while an over-bound closure emits resync and rehydrates only current interests rather than a graph-wide feed. |
| Fanout | Page, reference, property, and task dependency closure is exact until the bound, after which the typed resync sentinel replaces rather than truncates it. |
| Model-based | Random local insert, save, delete, journal-create, and task-status mutations plus remote-authoritative move, reorder, edit, delete-conflict, rebase, acknowledgement, block, and restart sequences agree with the naive oracle for every public read. |

Use the existing 100,000-block fixture and active outbox sizes of 0, 1, 32, 128, 1,024, and the configured 4,096-record or 8-MiB admission maximum.

Admission measurements charge every materialized outbox record, frozen delete artifact, bounded origin record, and protected wire, while retained-memory measurements charge only actually allocated canonical records, snapshots, and dispatcher data.

Measure these release-profile budgets on the repository reference machine:

| Operation | Required p95 |
| --- | ---: |
| `get_blocks` for 64 UUIDs | Less than 20 ms. |
| `get_structure` for 256 members | Less than 20 ms. |
| `get_journals` for 512 pages | Less than 25 ms. |
| Single-block logical change classification | Less than 10 ms. |
| Pure replan and logical diff for 128 active records | Less than 100 ms. |
| Reopen and index reconstruction for 1,024 active records | Less than 100 ms. |
| Maximum-admission `get_blocks` for 64 UUIDs | Less than 80 ms. |
| Maximum-admission `get_structure` for 256 members | Less than 80 ms. |
| Maximum-admission `get_journals` for 512 pages | Less than 100 ms. |
| Maximum-admission rebase and logical diff for 4,096 records | Less than 3.2 seconds. |
| Maximum-bound delete-conflict classification and rollback staging | Less than 3.2 seconds. |
| Maximum-admission reopen and index reconstruction for 4,096 records | Less than 500 ms. |

At maximum admission, peak auxiliary allocation for any point read or point mutation is less than 32 MiB, excluding the requested result and the one authoritative Datascript root.

Incremental retained RSS above the empty-outbox baseline is at most twelve times the active canonical outbox bytes plus 32 MiB.

That retained-RSS gate uses one live handle, no caller-retained historical snapshot, and caught-up subscribers; explicit snapshot retention and the bounded dispatcher journal are measured separately.

The manifest records those numeric gates, fixture checksum, compiler and dependency versions, machine class, and exact benchmark command before the implementation scaffold exists.

Instrumentation must prove that a point read does not scan the complete authoritative graph or complete outbox.

Storage instrumentation must also prove that `Storage_session` retains no second graph index and that compaction loads only the lazy physical nodes on paths touched by the bounded tail rather than serializing or scanning the authoritative graph.

Long-lived memory contains one authoritative Datascript root plus `O(outbox + active snapshots + bounded listener journal)` auxiliary memory.

There must be no second long-lived allocation trend proportional to authoritative graph size.

NOTE: I will write *all* tests before I add any implementation behavior.

Here, that rule is per behavior and per atomic ownership cutover: downstream tests may receive their already-specified final API wiring at the start of the combined Tasks 6-through-8 RED phase, but that wiring must execute and fail behaviorally before any corresponding production cutover code is changed.

### Global TDD and compile sequence

1. Treat every confirmed decision in this document as fixed implementation scope and verify that no open question remains before transition.
2. Create the approved canonical specification and package metadata.
3. Write every overlay, storage, concurrency, Sync, Worker, application, source-boundary, model-based, and performance test listed above before adding production overlay behavior.
4. Add only the minimum compile scaffold needed for the new virtual implementation to return typed unsupported results.
5. Run every new correctness test and confirm it executes and fails on the missing logical-overlay behavior rather than on a test defect, fixture defect, missing symbol, or build error.
6. Record the expected RED failures and do not begin implementation until all suites have a valid behavioral failure.
7. Implement the minimum bottom-up GREEN behavior in the task order below.
8. Treat Tasks 6 through 8 as one indivisible GREEN cutover because the `Storage_session`, Sync, Worker, mutation-type, and Dune removals have live callers across all three ownership boundaries.
9. Do not commit, publish, or require a repository-wide build between Tasks 6, 7, and 8, and do not retain a legacy facade to manufacture an intermediate buildable state.
10. Run only the batch-owned gates declared below after each earlier GREEN batch, keep later ownership gates as recorded RED, and run the complete suite after the combined Tasks 6-through-8 batch.
11. Refactor only after the corresponding batch is green.
12. Run the same suite again after each refactor and keep all previously green behavior green.

Use this RED-to-GREEN ownership matrix:

| Gate | Written and first RED | Required GREEN |
| --- | --- | --- |
| Canonical spec, unsupported facade, package-local boundary, and harness self-tests | Task 2 | Task 2 harness complete, with behavior assertions still RED. |
| Queryable outbox state machine, codec, receipt durability, corruption, and bounded indexes | Task 2 | Task 3. |
| Snapshot leases, UUID block/page reads, journal index, cursors, and logical composition | Task 2 | Task 4. |
| Pure logical planner, required-precondition coverage, read-set capture, deterministic intent, and pending chaining | Task 2 | Task 5. |
| Atomic local commit, authoritative transition, merged listener, storage ownership, Sync capabilities, mirror lifecycle, mutation-type deletion, Worker v2, UI locality, final source boundaries, and all performance gates | Task 2, with final compile-shape wiring refreshed before production changes at the start of Task 6 | End of the combined Tasks 6-through-8 cutover. |

Mutation-identity removal, final migration boundaries, Worker v2 integration, and app integration are intentionally recorded RED gates during Tasks 3 through 5 and are not counted as failures of those earlier GREEN batches.

## Implementation Plan

### Task 1: Freeze the overlay specification and package boundary

Files to create:

- `logseq_overlay_db/spec/dune`.
- `logseq_overlay_db/spec/types.mli`.
- `logseq_overlay_db/spec/database.mli`.
- `logseq_overlay_db.opam`.
- `logseq_overlay_db.opam.locked`.
- `test/logseq_overlay_db_boundary_test.ml`.

Files to modify:

- `dune-project`.
- `test/source_boundary_test.ml`.
- `test/dune`.

Execution steps:

1. Add the `test/logseq_overlay_db_boundary_test.ml` executable stanza and assertions requiring the new package, opam files, virtual specification, default implementation, and public module names.
2. Make that package-local gate forbid Datascript databases, connections, entity IDs, decoded transaction operations, durable outbox encodings, Worker imports, Sync imports, raw string-list outbox replacements, and `Logseq_db_types.Mutation.t` throughout `logseq_overlay_db/spec`; within `Types.local_mutation`, write preconditions, and public request/list selectors, additionally forbid generic page kinds, generic property selectors or values, and generic insertion positions, while explicitly permitting complete read-only block and page result DTOs to carry authoritative kind/property metadata.
3. Make that package-local gate forbid any long-lived `projected_db`, `projected_conn`, `Projected_connection`, or duplicate authoritative `Datascript.db` in new overlay production code, and place removal of the existing authoritative root plus long-lived physical EAVT/AEVT/AVET set fields inside `Storage_session.t` in the separate final migration gate that stays RED until Task 8.
4. Define every referenced revision codec, constructor, accessor, result record, lifecycle operation, and operation-specific error in the two canonical interfaces without ellipses.
5. Configure internal virtual library `logseq_overlay_db` with public name `logseq_overlay_db`, virtual modules `Types` and `Database`, and declared default implementation `logseq_overlay_db_impl` without creating the implementation scaffold yet.
6. Add the package stanza and exact dependency metadata.
7. Add `(source_tree ../logseq_overlay_db)` plus `../logseq_overlay_db.opam`, `../logseq_overlay_db.opam.locked`, and `../logseq_overlay_db.install` dependencies to `test/dune`, and keep `test/source_boundary_test.ml` as the separate final migration/deletion gate that is expected to remain RED until Task 8.
8. Generate locked metadata with `opam lock ./logseq_overlay_db.opam` only after its dependencies are installed in the active switch.
9. Stop before adding `Types.ml`, `Database.ml`, or any production behavior and proceed directly to the complete RED suite.

### Task 2: Write and verify the complete RED suite

Files to create:

- `logseq_overlay_db/lib/dune`.
- `logseq_overlay_db/lib/types.ml`.
- `logseq_overlay_db/lib/database.ml`.
- `logseq_overlay_db/test/dune`.
- `logseq_overlay_db/test/test_support.ml`.
- `logseq_overlay_db/test/naive_projection_oracle.ml`.
- `logseq_overlay_db/test/test_overlay_reads.ml`.
- `logseq_overlay_db/test/test_overlay_mutations.ml`.
- `logseq_overlay_db/test/test_overlay_changes.ml`.
- `logseq_overlay_db/test/test_overlay_sync.ml`.
- `logseq_overlay_db/test/test_overlay_storage.ml`.
- `logseq_overlay_db/test/test_overlay_concurrency.ml`.
- `logseq_overlay_db/test/test_performance.ml`.
- `logseq_overlay_db/test/fixtures/performance/100000-blocks-v1.manifest.json`.
- `logseq_overlay_db/tool/dune`.
- `logseq_overlay_db/tool/fixture_generator.ml` and `.mli`.
- `logseq_overlay_db/tool/performance_benchmark.ml`.
- `logseq_overlay_db/tool/test_performance.sh`.
- `logseq_db_worker/test/fixtures/protocol/v2-command-catalog.json`.
- `logseq_db_worker/test/fixtures/protocol/v2-operation-contracts.json`.
- `logseq_db_worker/test/fixtures/protocol/v2-outcome-catalog.json`.
- `logseq_db_worker/test/test_overlay_integration.ml`.

Files to modify:

- `logseq_db_types/test/test_mutation_identity.ml`.
- `test/logseq_overlay_db_boundary_test.ml`.
- `logseq_db_worker/test/dune`.
- `logseq_db_worker/test/test_protocol.ml`.
- `logseq_db_worker/test/test_effect_runner.ml`.
- `logseq_db_worker/test/test_storage_atomicity.ml`.
- `logseq_db_worker/test/test_managed_sync_e2e.ml`.
- `logseq_sync/test/test_sync.ml`.
- `test/logseq_db_worker_application_integration_test.ml`.
- `test/source_boundary_test.ml`.

Execution steps:

1. Write all behavior cases from the Testing Plan before creating the default implementation scaffold or implementing `Queryable_outbox`, logical reads, local writes, authoritative transitions, or listener merging, and make the v2 fixtures enumerate only the confirmed current-App operations.
2. Use the package public interfaces in every production-facing test.
3. Exercise cursor, codec, correlation, and checksum behavior through the public `Database` facade and never import Dune private implementation modules from test executables.
4. Centralize every overlay `Types.local_mutation` test constructor in `logseq_overlay_db/test/test_support.ml` and every overlay tool constructor in `logseq_overlay_db/tool/fixture_generator.ml`, with a source assertion that no new test or tool imports or constructs the deleted `Logseq_db_types.Mutation` shapes.
5. Make the naive oracle small, deterministic, and test-only.
6. Add RED assertions that mutation identity contains no global basis and that the obsolete basis-oriented success type is absent, while leaving production mutation types unchanged until the coordinated Task 8 cutover.
7. Freeze the 100,000-block fixture manifest with every numeric ordinary and maximum-admission latency, allocation, retained-RSS, and index-access gate, and implement a deterministic test-only lower-storage seed builder without importing Worker code.
8. After every test file exists, create `Types.ml`, `Database.ml`, and implementation Dune stanzas that only return typed unsupported results and perform no requested behavior.
9. Set `(include_subdirs qualified)` in `logseq_overlay_db/lib/dune`, configure `logseq_overlay_db_impl` with public name `logseq_overlay_db.impl` and `(implements logseq_overlay_db)`, and keep every module except `Types` and `Database` private.
10. Run every new behavior-test executable plus `dune exec logseq_db_types/test/test_mutation_identity.exe`, verify their assertions fail for the expected missing behavior, and keep harness self-tests plus the package-local boundary gate GREEN.
11. Fix test and fixture defects until every failure is behavioral rather than a compiler, setup, or accidental exception failure.
12. Include explicit RED barriers for removal of every unused Worker operation, lease release and close, unrelated local-write interleavings, delete conflict rollback and non-execution proof across restart, receipt idempotency, every outbox-state rebase, crypto correlation, dispatcher capacity, slow listeners, post-commit crash recovery, mirror lifecycle, and v2 Worker change windows.
13. Extend `logseq_db_worker/test/test_managed_sync_e2e.ml` with bounded two-client stale-`t_before`, frozen-request retry, server-normalized Pull and separate `outliner-op` round-trip, contiguous non-interleaved group cursors, accepted-before-remote, and remote-before-delete scenarios, run `dune build @logseq_db_worker/test/managed-sync-online-e2e` with the dedicated credentials, and block production implementation if the deployed service cannot prove the required conditional-barrier and ordering contract.
14. Run `dune exec test/logseq_overlay_db_boundary_test.exe -- "$PWD" _build/default/logseq_overlay_db.install` and make the package-local scaffold boundary GREEN, then separately record the expected final-migration RED output from `test/source_boundary_test.exe` without treating that final gate as an intermediate GREEN requirement.
15. Run the benchmark harness at 1,024 records and the configured admission maximum and verify its RED self-test rejects typed `Unsupported`, missing samples, zero-duration placeholders, and absent allocation or RSS counters; real latency thresholds become eligible only after the measured public operations are GREEN.

### Task 3: Extract the durable queryable outbox

Files to create:

- `logseq_overlay_db/lib/overlay_effect.ml` and `.mli`.
- `logseq_overlay_db/lib/queryable_outbox.ml` and `.mli`.
- `logseq_overlay_db/lib/mutation_receipt.ml` and `.mli`.
- `logseq_overlay_db/lib/delete_conflict.ml` and `.mli` for bounded frontier, footprint, guard, rollback-window, origin-evidence, and resolution-state codecs.
- `logseq_overlay_db/lib/crypto_bridge.ml` and `.mli`.
- `logseq_overlay_db/lib/sync_tx_codec.ml` and `.mli`.
- `logseq_overlay_db/lib/authoritative_store.ml` and `.mli` with restore and sole-connection ownership but no authoritative transition yet.
- `logseq_overlay_db/lib/ownership.ml` and `.mli`.
- `logseq_overlay_db/lib/mirror.ml` and `.mli` with inspect, attachment, existing-mirror open, and close only.
- `logseq_db_storage/lib/mutation_receipt_store.ml` and `.mli`.

Files to modify:

- `logseq_db_storage/lib/sync_outbox_store.ml` and `.mli`.
- `logseq_db_storage/lib/logseq_sqlite_storage.ml` and `.mli`.
- `logseq_db_storage/lib/storage_session.ml` and `.mli`.
- `logseq_db_worker/test/test_storage_atomicity.ml` for lower-storage callback and batch record construction affected by the new atomic receipt fields.

Execution steps:

1. Move canonical outbox state, record codec, normalized local transaction encoding, and validation limits out of Sync.
2. Separate stable semantic intent, transport state, replannable queued effects, and frozen submitted effects in one canonical durable record.
3. Implement ordered block, page, structure, tombstone, reverse-dependency, delete-footprint, conflict-guard, rollback-window, rejected-delete catch-up, and terminal origin-evidence indexes.
4. Preserve the existing durable count and byte bounds, charge every frozen delete artifact and bounded origin-evidence record at admission, and expose changing usage only through administrative inspection rather than logical `graph_info`.
5. Make corrupt, duplicate, unsorted, oversized, or non-canonical records fail closed.
6. Persist generated UUIDs, client timestamps, and semantic anchors once, while deterministically recomputing only unsent queued order values and payloads.
7. Add the durable mutation-receipt index plus the exact-lookup `terminal_receipts_by_batch_id` secondary index, atomically move incorporated or terminal records from active outbox state to compact receipts, and retain every unresolved rejected-delete catch-up artifact.
8. Keep `logseq_db_storage` receipt APIs limited to namespace-safe fixed-size opaque keys plus opaque encoded bytes, allowing exact mutation-ID and submission-batch-ID indexes without importing overlay types; canonical key construction, receipt codec, and validation remain owned only by overlay.
9. Implement the exact ordinary and delete-conflict state matrix and forbid a frozen Submitted or Accepted payload from being silently replanned.
10. Implement bounded atomic submission-group creation, delete singleton enforcement, exact timeout retry, acceptance barriers, and validated partial-rejection partitioning without ever persisting an incomplete group.
11. Restrict storage's encoded-outbox and receipt commits to the overlay implementation boundary.
12. Implement the final-form ownership, mirror inspection, attachment, existing-fixture `open_`, `close`, and `inspect_sync` paths needed to exercise the outbox and receipt behavior through the public facade, while leaving snapshot activation and authoritative commit unsupported.
13. Implement same-fingerprint active-resolution and receipt lookup before fresh-mutation planning so seeded applied, remote-won, blocked, and discarded histories can be verified through `prepare_local` even though fresh planning remains Task 5.
14. Keep the existing Sync-owned codec and production mutation types untouched until Tasks 7 and 8 can update all callers and Dune dependencies in coordinated buildable cutovers.
15. Run the outbox, ordinary and delete-conflict state-matrix, singleton enforcement, submission-group atomicity, partial and Stale rejection, frozen-artifact admission and corruption, rejection-first catch-up and non-retry eligibility, maximum-admission, existing-mirror open/close, restart, receipt-idempotency, and package-local overlay-boundary suites while leaving the recorded final migration/deletion gate RED until Task 8.

### Task 4: Implement logical snapshots and UUID-based reads

Files to create:

- `logseq_overlay_db/lib/logical_snapshot.ml` and `.mli`.
- `logseq_overlay_db/lib/overlay_read.ml` and `.mli`.
- `logseq_overlay_db/lib/query_cursor.ml` and `.mli`.

Existing behavior sources to retain unchanged until the coordinated Task 8 cutover:

- `logseq_db_worker/lib/read_model.ml` and `.mli`.
- `logseq_db_worker/lib/query.ml` and `.mli`.

Execution steps:

1. Capture authoritative root, logical-outbox root, and all snapshot versions in one tracked lease at one linearization point.
2. Implement deterministic lease release, close invalidation, and typed reads-after-release or close before adding graph reads.
3. Implement logical graph information and canonical UUID lookup against authoritative Datascript indexes without exposing entity IDs or a Datascript basis.
4. Implement field-level block and page composition plus journal listing by applying only active ordered outbox effects; `Delete_barrier_rejected_pending_authoritative` retains its frozen effect until catch-up resolves, while a terminal `Remote_won` receipt contributes no effect and needs no repair cache.
5. Implement tombstones and explicit Missing results with target-local revisions, including atomically removing every tombstone and auxiliary effect owned by a conflicted delete.
6. Implement deterministic journals and the closed structure request and result variants with authenticated fixed-snapshot cursors.
7. Implement target-state and scope-state digests without a graph-sized revision cache.
8. Expand render dependencies for page metadata, references, tags, properties, and task state.
9. Prove point reads access only requested authoritative indexes and matching outbox effects.
10. Keep the Worker-owned read and cursor implementations in place because their callers still compile against them until Task 8.
11. Run lease, graph-info, admission-inspection, snapshot, block, journal-list, structure, tombstone, conflicted-delete deactivation, dependency, cursor, and model-based suites.

### Task 5: Move mutation planning onto the logical overlay

Files to create:

- `logseq_overlay_db/lib/overlay_planner.ml` and `.mli`.
- `logseq_overlay_db/lib/outliner_order.ml` and `.mli`.
- The smallest private outliner modules required by closed `Save_block`, append-to-parent `Insert_blocks`, single-root `Delete_blocks`, direct `Create_journal_page`, `Set_task_status`, and `Clear_task_status`.

Existing behavior sources to retain unchanged until the coordinated Task 8 cutover:

- `logseq_db_worker/lib/mutation_plan.ml` and `.mli`.
- `logseq_db_worker/lib/outliner_order.ml` and `.mli`.
- Only the private Worker outliner modules that supply the confirmed App mutation behavior.

Execution steps:

1. Introduce a private `Graph_view` that exposes UUID-based logical block, page, and structure reads to planners.
2. Move only the six closed current-App mutation planners to `Overlay_planner` without preserving a raw authoritative-DB execution path, generic page/property adapters, or generic insertion positions, and mark every unused planner branch for deletion without replacement in Task 8.
3. Make planners produce stable semantic intent plus deterministic queued overlay effects and queued Sync submission material.
4. Validate only the constructor-specific block, page, and structure-scope revisions actually observed by the UI, then internally capture every additional logical read dependency revision, including fixed status-property definition and schema state, on each prepared local mutation.
5. Make `prepare_local Delete_blocks` compute and bound its candidate UUID frontier, complete write footprint, negative conflict guard, and rollback window, then make `commit_local` revalidate and atomically freeze and persist those exact artifacts with the Queued record before publishing the delete effect.
6. Cover the current planner's comment-area cleanup, external reference retractions, source-title rewrites, timestamps, transaction metadata, and default-property-holder branches in that footprint rather than treating hard deletion as frontier tombstones alone.
7. Plan a new mutation against the authoritative root plus all earlier active outbox effects in order.
8. Define pending-on-pending chaining without any basis inside the overlay planner, while retaining the existing Worker `expected_basis` construction only until Task 8 updates every caller and deletes the legacy mutation interface in the same cutover.
9. Implement the pure read-set comparison used by commit, while deferring its atomic lane reacquisition and persistence wiring to the combined Tasks 6-through-8 cutover.
10. Keep semantic UUIDs, timestamps, anchors, delete frontiers, guards, and rollback windows stable, rederive only never-submitted ordinary queued order and payload data, and freeze effects and payload after submission.
11. Keep the Worker-owned planner and required outliner modules in place until Task 8 performs the single caller, type, Dune, and deletion cutover.
12. Run the confirmed-surface planning, required-precondition, pending chaining, stale-dependency comparison, deterministic intent, delete-footprint and rollback-window completeness, artifact admission, structure, and planner-oracle gates owned by Task 5, while atomic commit, conflict resolution, receipt idempotency, and concurrent interleaving gates remain recorded RED until Task 8.

### Task 6: Implement atomic transitions and merged logical change delivery

This task is the first workstream of the indivisible Tasks 6-through-8 GREEN cutover, so its breaking storage API changes must be completed together with the Sync and Worker caller rewrites before any repository-wide build or commit.

Before changing any production file in these three tasks, apply the final canonical API wiring to every test and fixture listed under Tasks 6, 7, and 8, run the combined targeted gates, and record behavioral RED for the missing atomic transition, Sync, Worker, UI, deletion, and performance behavior.

Files to create:

- `logseq_overlay_db/lib/logical_change.ml` and `.mli`.
- `logseq_overlay_db/lib/transition.ml` and `.mli`.
- `logseq_overlay_db/lib/change_dispatcher.ml` and `.mli`.
- `logseq_overlay_db/lib/authoritative_checksum.ml` and `.mli`.

Files to modify:

- `logseq_overlay_db/lib/authoritative_store.ml` and `.mli`.
- `logseq_overlay_db/lib/database.ml`.
- `logseq_db_storage/lib/storage_session.ml` and `.mli`.
- `logseq_db_storage/lib/logseq_sqlite_storage.ml` and `.mli`.
- `logseq_db_worker/test/test_storage_atomicity.ml` until its lower-storage cases move to the overlay suite in Task 8.

Execution steps:

1. Serialize all authoritative, outbox, receipt, and checkpoint transitions through one package-owned execution lane.
2. Refactor `Storage_session.t` to retain physical root addresses and counts, durable tail, SQLite callbacks, allocation metadata, and lifecycle only, with no authoritative `Datascript.db`, long-lived EAVT/AEVT/AVET set fields, or `current_db` accessor.
3. Make restore return the initial immutable root to `Authoritative_store`, and make every storage staging call accept its captured `A_before` explicitly.
4. Install one private `Datascript.listen` callback on the sole authoritative connection plus one private queryable-outbox transition listener.
5. Capture immutable logical before state, stage logical after state, and retain their exact direct candidate UUIDs and structure interests while holding the transition lane.
6. Assign one package commit identifier plus zero-based ordinal and total count to every pure staged authoritative transaction, repeat that metadata on its later connection transaction, and assign the commit identifier to the staged outbox fragment.
7. Stage every ordered sparse authoritative transaction from `A_before` through pure `Datascript.with_tx` with `skip-store? = true`, preserve every transaction boundary and intermediate root, and make `Storage_session` prepare the corresponding physical SQLite batch through short-lived lazy physical-index paths without retaining any staged root or physical set after the lease ends.
8. At each transaction ordinal, use validated cursor intervals plus exact frozen-member simulation against that ordinal's `db-before` to distinguish Remote, own original-delete, and other own-submission transactions independently of message arrival order, compare normalized datom multisets rather than implementation-specific list order, evaluate every active delete guard only for proven Remote changes, and retain the exact intermediate roots needed to order remote-before-delete and remote-after-own-delete cases.
9. For a causally-prior conflict, deactivate a complete Queued delete immediately; for Submitted, allow immediate terminal rollback only when the first occupied cursor itself conflicts, otherwise retain the complete bounded Pull window until Stale supplies `through`, persist the earliest conflict cursor plus canonical sorted conflict-kind set only for ordinals at or before that boundary, and fail Sync integrity if acceptance or own incorporation contradicts the exact conditional barrier.
10. Validate a conflict-free incorporated delete's actual touched facts against its frozen write footprint and fail closed on any out-of-footprint `RetractEntity` cascade.
11. At the exact Stale rejection-cursor ordinal, resolve terminal priority from the accumulated conflict evidence and that intermediate root, then treat every later ordinal in the same Pull as normal post-delete authoritative state; expand the rollback window through final guard entities, exact reverse dependencies, and old and new page or structure scopes, then derive one `logical_change_summary` by comparing canonical logical state across the complete before and staged-after snapshots.
12. Emit no event for `No_logical_change`, one exact event for a bounded exact summary, and one explicit resync event when exact classification exceeds its limit.
13. Reserve a bounded revision-ordered dispatcher slot and construct the complete immutable commit result and event before durable commit.
14. Apply backpressure or return typed busy before durability when no slot can be reserved.
15. Complete every decode, replan, conflict classification, allocation, checksum, candidate validation, logical comparison, and storage staging step that can ordinarily fail before durability.
16. Atomically commit authoritative data, authoritative checkpoint, ordinary outbox transitions, delete-conflict state, origin evidence, and mutation receipts in SQLite, using that commit as the transition linearization point.
17. On a pre-commit storage failure, discard the staged root, staged outbox, prepared result, and reserved event state while the sole connection remains on `A_before` and no listener event is published.
18. After durability, replay each authoritative transaction exactly once and in order through `Datascript.transact_conn` on the sole connection with `skip-store? = true` plus the same commit ID and ordinal/count metadata.
19. Collect all synchronous private listener reports by commit ID and verify each report's adjacency, ordinal/count, sparse transaction data, counters, tempids, and affected point results against its corresponding staged report without `db_hash`, `Datascript.diff`, or any index scan.
20. After that equivalence check succeeds, publish the staged outbox root, logical revisions, prepared commit result, and reserved event slot without further fallible graph work, then invoke public callbacks outside the transition lane.
21. Treat an unexpected post-commit connection transaction, listener-fragment, equivalence, or publication failure as fatal, never call `reset_conn`, reopen from SQLite with a fresh generation, and force Worker interested-state bootstrap.
22. Coalesce a slow subscriber that exceeds retention to one resync notification without allowing unbounded memory, and enforce the documented unlisten and close postconditions.
23. At the end of Task 8, run delete-conflict ordinal classification, exact-`t_before` non-execution, server-normalized Pull and separate-`outliner-op` round-trip, `RetractEntity` write-footprint validation, rejection-first catch-up restart, equivalent-delete `No_change`, remote-after-own-delete no-flash ordering, single- and multi-transaction private-listener merge, transaction-boundary and ordinal/count preservation, sole-connection ownership, sparse-authoritative allocation, bounded equivalence with forbidden graph hashes and diffs, no-`reset_conn`, no-precommit-Datascript-store, staged-root discard, paused-subscription activation, pre-activation overflow, queue-full, slow-subscriber, unlisten races, concurrent-commit ordering, close-with-backlog, atomicity, listener reentrancy, listener failure, post-commit crash, equivalence-failure, generation-reset, and restart suites.

### Task 7: Move the durable data plane out of Sync

This task is the second workstream of the indivisible Tasks 6-through-8 GREEN cutover and must not leave a temporary compatibility constructor in Sync for the old Worker.

Files to complete in `logseq_overlay_db/lib/` while retaining the Worker behavior sources until Task 8:

- `logseq_overlay_db/lib/ownership.ml` and `.mli`, using `logseq_db_worker/lib/ownership.ml` and `.mli` as behavior sources.
- `logseq_overlay_db/lib/mirror.ml` and `.mli`, using `logseq_db_worker/lib/synced_mirror.ml` and `.mli` as behavior sources.
- `logseq_overlay_db/lib/snapshot_parser.ml` and `.mli`, created using `logseq_db_worker/lib/synced_snapshot_parser.ml` and `.mli` as behavior sources.

Files to migrate into `logseq_overlay_db/lib/` and delete from Sync after GREEN:

- The outbox record codec currently embedded in `logseq_sync/lib/pure_reducer/core.ml`.
- `logseq_sync/lib/pure_reducer/pure_tx.ml`.
- `logseq_sync/lib/pure_reducer/checksum.ml` and `.mli`.

Files to modify:

- `logseq_sync/spec/pure_reducer/core.mli`.
- `logseq_sync/spec/effect_runner/effect_runner.mli`.
- `logseq_sync/lib/pure_reducer/core.ml`.
- `logseq_sync/lib/effect_runner/effect_runner.ml`.
- `logseq_sync/spec/pure_reducer/dune`.
- `logseq_sync/lib/pure_reducer/dune`.
- `logseq_sync/spec/effect_runner/dune`.
- `logseq_sync/lib/effect_runner/dune`.
- `logseq_sync/test/dune`.
- `logseq_sync/test/test_sync.ml`.
- `logseq_sync/test/core_contract.ml`.
- `logseq_sync/test/runner_contract.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_01_unowned_snapshot_progress.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_02_duplicate_mirror_inspection.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_03_duplicate_graph_attachment.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_04_duplicate_websocket_open.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_05_message_after_websocket_close.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_06_unsolicited_authoritative_apply.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_07_restore_accepts_old_catalog.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_08_reused_graph_token_challenge.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_09_unsolicited_local_commit.ml`.
- `logseq_sync/test/test_pure_reducer_bad_case_10_mismatched_outbox_commit.ml`.
- `logseq_sync.opam`.
- `logseq_sync.opam.locked`.

Files to delete only at the end of the combined Task 8 cutover:

- Sync-owned outbox codec modules.
- Sync-owned `pure_tx` modules.
- Sync-owned authoritative checksum modules.
- Raw Datascript DB and transaction-operation paths superseded by the typed overlay API.

Execution steps:

1. Replace Sync's raw database, transaction, checksum, and encoded-outbox inputs with typed overlay inspection and transition handles.
2. Keep transport scheduling, network protocol, E2EE, retry, authentication, and remote error policy inside Sync.
3. Connect Sync crypto effects to bounded request accessors, chunked snapshot activation, and validated response constructors without exposing semantic records.
4. Commit one bounded first-submission group atomically as `Submitted` before sending, enforce singleton groups for deletes, and return only its complete stored `submission_batch` DTO.
5. Keep timeout retries byte-identical, while mapping validated partial rejection into accepted prefix, failed or dependent blocked members, one independent frozen suffix retry group, or the delete-specific Stale catch-up state; a rejected or terminal remote-won delete is not resent automatically.
6. Keep every accepted submission member logically active until an authoritative transition processes its group's acceptance barrier or a late acknowledgement proves the continuous checkpoint passed that barrier; when Pull-first conflict terminalizes a delete before its unlabelled response, retain a connection-scoped `Terminal_awaiting_response` owner with retry disabled until ACK, rejection, or WebSocket-epoch close, and treat any late acceptance as integrity failure.
7. Let overlay classify a singleton delete's first continuous Pull transaction from the exact expected cursor and the frozen member's simulated server-normalized datom multiset against that cursor's `db-before`; on `Authoritative_deferred`, retain only the original bounded opaque authoritative batch, allow only a conflict at that first occupied cursor to terminate before response, hold an unrelated or equivalent first transaction plus every later ordinal until ACK or Stale rejection supplies the exact window boundary, then reprepare and apply authoritative batches, checkpoints, receipts, rejected-delete catch-up, and outbox lifecycle changes only through one overlay transition.
8. Keep authoritative preparation handles in the Worker effect runner rather than Sync pure state.
9. Make duplicate and stale transport responses harmless through stable mutation and batch IDs plus expected-state compare-and-set operations; require Sync to attach its current connection owner batch ID to both acceptance and rejection transitions, and test duplicate, absent-owner, foreign-batch, and terminal-receipt correlation explicitly.
10. Implement mirror-generation compare-and-set, exclusive-open revalidation, bounded snapshot crypto batches, and deterministic temporary-artifact cleanup behind the public overlay lifecycle API.
11. Remove direct dependencies from Sync to Datascript, storage internals, Worker mirror ownership, durable outbox records, and decoded authoritative operations.
12. Stage deletion of only the Sync-owned codec, pure transaction, and checksum paths, but apply that deletion in the same final patch that Task 8 uses to update every Worker caller.
13. At the end of Task 8, run crypto-correlation, chunk bounds, cancellation cleanup, stale-mirror race, atomic submission group, delete singleton groups, frozen full-group retry, partial rejection partition, all-state remote-reorder, ACK-before-Pull, Pull-before-ACK, rejection-before-Pull, and Pull-before-rejection delete cases, server-normalized Pull and separate-`outliner-op` round-trip, stale-`t_before` non-execution, terminal-awaiting-response late rejection, fatal late ACK, WebSocket-epoch close, equivalent-delete `No_change`, remote-after-own-delete ordering, receipt-idempotency, duplicate response, state-aware blocked dependency, mirror activation, restart, E2EE, and source-boundary suites.

### Task 8: Replace the Worker engine with the overlay package

This task completes the indivisible Tasks 6-through-8 GREEN cutover, applies all staged deletions, restores a buildable repository without compatibility paths, and is the first point at which the combined batch may be committed.

Files to modify:

- `logseq_db_types/lib/dune`.
- `logseq_db_types.opam` and `logseq_db_types.opam.locked`.
- `logseq_db_types/lib/sync_status.ml` and `.mli`.
- `logseq_db_types/lib/graph_types.ml` and `.mli`.
- `logseq_overlay_db/test/test_support.ml`.
- `logseq_overlay_db/tool/fixture_generator.ml` and `.mli`.
- `logseq_db_worker/spec/pure_reducer/core.mli`.
- `logseq_db_worker/spec/effect_runner/effect_runner.mli`.
- `logseq_db_worker/contract/protocol.ml` and `.mli`.
- `logseq_db_worker/contract/error.ml` and `.mli`.
- `logseq_db_worker/contract/config.ml` and `.mli`.
- `logseq_db_worker/lib/pure_reducer/core.ml`.
- `logseq_db_worker/lib/effect_runner/effect_runner.ml`.
- `logseq_db_worker/lib/logseq_db_worker.ml` and `.mli`.
- `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml` and `.mli`.
- `logseq_db_worker/lib/dune`.
- `logseq_db_worker/spec/pure_reducer/dune`.
- `logseq_db_worker/spec/effect_runner/dune`.
- `logseq_db_worker/lib/pure_reducer/dune`.
- `logseq_db_worker/lib/effect_runner/dune`.
- `logseq_db_worker/contract/dune`.
- `logseq_db_worker/bonsai/dune`.
- `logseq_db_worker/test/dune`.
- `logseq_db_worker/tool/dune`.
- `logseq_db_worker.opam`.
- `logseq_db_worker.opam.locked`.
- `logseq_db_worker/test/adapter_fixture.ml`.
- `logseq_db_worker/test/test_bonsai_service.ml`.
- `logseq_db_worker/test/test_effect_runner.ml`.
- `logseq_db_worker/test/test_fixture_generator.ml`.
- `logseq_db_worker/test/test_managed_sync_e2e.ml`.
- `logseq_db_worker/test/test_overlay_integration.ml`.
- `logseq_db_worker/test/test_pure_reducer.ml`.
- `logseq_db_worker/test/structural_fixture.ml`.
- `logseq_db_worker/tool/fixture_generator.ml` and `.mli`.
- `logseq_db_worker/tool/mutation_identity_benchmark.ml`.
- `app/application.ml` and `.mli`.
- `app/dune`.
- `app/journal_header.ml` and `.mli`.
- `app/journal_startup.ml` and `.mli`.
- `app/journal_platform.ml` and `.mli`.
- `app/journal_graph_projection.ml` and `.mli`.
- `app/journal_graph_request.ml` and `.mli`.
- `app/journal_graph_runtime.ml` and `.mli`.
- `app/journal_graph_transport.ml` and `.mli`.
- `test/application_view_test.ml`.
- `test/journal_semantics_test.ml`.
- `test/journal_runtime_golden_fixture.ml`.
- `test/logseq_db_worker_application_integration_test.ml`.
- `test/managed_application_fixture.ml`.
- `test/source_boundary_test.ml`.
- `test/startup_test.ml`.

Files to delete after GREEN:

- `logseq_db_types/lib/mutation.ml` and `.mli` after all identity assertions move to overlay and Worker-v2 tests.
- `logseq_db_types/test/test_mutation_identity.ml` and `logseq_db_types/test/dune` after their still-relevant identity and source-boundary assertions move to overlay and Worker-v2 tests.
- `logseq_db_worker/lib/engine.ml` and `.mli`.
- `logseq_db_worker/lib/read_model.ml` and `.mli`.
- `logseq_db_worker/lib/query.ml` and `.mli`.
- `logseq_db_worker/lib/mutation_plan.ml` and `.mli`.
- `logseq_db_worker/lib/outliner_order.ml` and `.mli`.
- `logseq_db_worker/lib/outliner/` after every retained current-App caller has moved; delete all remaining unused modules without an overlay replacement.
- `logseq_db_worker/lib/ownership.ml` and `.mli`.
- `logseq_db_worker/lib/synced_mirror.ml` and `.mli`.
- `logseq_db_worker/lib/synced_snapshot_parser.ml` and `.mli`.
- Entity-ID, graph-wide invalidation, and projected-connection paths superseded by UUID-scoped logical changes.
- `logseq_db_worker/test/fixtures/protocol/v1-command-catalog.json`.
- `logseq_db_worker/test/fixtures/protocol/v1-operation-contracts.json`.
- `logseq_db_worker/test/fixtures/protocol/v1-outcome-catalog.json`.
- `logseq_db_worker/test/test_engine_managed.ml`.
- `logseq_db_worker/test/test_storage_atomicity.ml` after its still-relevant lower-storage cases move to `logseq_overlay_db/test/test_overlay_storage.ml`.
- `logseq_db_worker/test/fixtures/performance/100000-blocks-v1.manifest.json`.
- `logseq_db_worker/test/fixtures/performance/reference-apple-silicon-v1.json`.
- `logseq_db_worker/test/test_performance.ml`.
- `logseq_db_worker/tool/performance_benchmark.ml`.
- `logseq_db_worker/tool/test_performance.sh`.

Execution steps:

1. Define Worker protocol v2 with generation, adjacent projection revisions, UUID and scope change windows, projection-bound pull cursors, acknowledgement, retention overflow resync, and constructor-specific target-local preconditions only for the confirmed App operation set.
2. In one buildable type-and-caller cutover, replace the generic `Logseq_db_types.Mutation.t`, its nested context/page/property/position types, its codec, and `Mutation.success` with six closed Worker-v2 request shapes that map one-to-one into `Types.local_mutation`, then delete the old module and every unused read or mutation constructor, fixture, and Dune module reference without aliases; remove the now-unused `digestif` and `yojson` dependencies from `logseq_db_types/lib/dune` and package metadata; also delete the obsolete `Sync_status.state`, `t`, `pending`, and `success` records while retaining `Sync_status.activity`, and delete the old basis-bearing `Graph_types.graph_info` instead of aliasing it upward.
3. Replace every caller of those deleted shapes with overlay commit, sync-view, and graph-info types in the same patch.
4. Replace v1 `Graph_invalidated` fixtures and implementation in one cutover without a compatibility decoder.
5. Make each Worker session hold one `Logseq_overlay_db.Database.t` rather than an `Engine.t` with a projected connection.
6. Replace the App's fixed `List_pages Only_journals` call with the dedicated journal-list request, map only graph-info, journal listing, explicit page, explicit block, page-tree, and child requests to leased overlay reads, and always release the lease; delete generic page-list protocol and codec shapes.
7. Translate the current App's generic page/property calls into direct `Create_journal_page`, `Set_task_status`, or `Clear_task_status` requests while updating the callers, map only the six closed Worker-v2 variants to `Types.local_mutation`, return logical revisions rather than a Datascript basis, and delete generic `Create_page`, `Set_property`, `Remove_property`, insertion-position, and every other unused Worker operation without an overlay replacement.
8. Pass typed overlay Sync and mirror lifecycle capabilities to Sync effects without exposing storage or Datascript values through the Worker contract.
9. Subscribe once to overlay projection changes and append v2 Worker change-journal entries containing generation, adjacent revisions, block UUIDs, page UUIDs, and structure interests.
10. On generation change, clear the old Worker journal, return mandatory resync, and bootstrap the UI's current interests before accepting incremental ACKs.
11. Make the UI compare its interested UUIDs and scopes with each change window, issue no read for an empty intersection, hydrate only intersecting UUIDs or scopes, and replace only affected normalized Bonsai fragments while preserving unrelated row identity and revision. For remote-wins, build the candidate window from the complete frozen write footprint, newly observed guard entities, exact reverse render dependents, and affected page UUIDs plus old and new structure scopes; refetch interested external ref sources, rewritten titles, page metadata, comment areas, and property holders even when they sit outside the visible subtree, and use the resync sentinel rather than a truncated list when the bound is exceeded.
12. Delete every listed Worker data-plane source only after its final caller and Dune module reference has moved, in the same Task 8 cutover.
13. Delete every `Engine` re-export and caller, entity-ID conversion, graph-wide refresh, projected-DB, v1 invalidation, and duplicate authoritative-plus-outbox composition path.
14. Replace direct app imports of Sync reducer DTOs with Worker-owned presentation and lifecycle DTOs, then remove the direct Sync reducer dependency from `app/dune`.
15. Keep the UI coupled only to the Worker protocol and never directly to `logseq_overlay_db` or Sync internals.
16. Run current-App-surface source assertions that reject generic page listing, generic page kinds, property selectors or values, and insertion positions in mutation/write-request shapes plus every old `Logseq_db_types.Mutation` import, while allowing complete read-only block/page DTO metadata; then run mutation-identity, v2 fixture, protocol, reducer, effect-runner, remote-wins full-window locality, migrated `logseq_overlay_db/test/test_overlay_storage.ml` atomicity cases, Bonsai service, generation-reset, app integration, tool, and source-boundary suites.

### Task 9: Complete package wiring and repository verification

Files to create or modify:

- `dune-project`.
- `logseq_db_types/lib/dune`.
- `logseq_db_types.opam` and `logseq_db_types.opam.locked`.
- `logseq_overlay_db.opam`.
- `logseq_overlay_db.opam.locked`.
- `logseq_overlay_db/spec/dune`.
- `logseq_overlay_db/lib/dune`.
- `logseq_overlay_db/test/dune`.
- `logseq_overlay_db/tool/dune`.
- `logseq_sync/spec/pure_reducer/dune`.
- `logseq_sync/lib/pure_reducer/dune`.
- `logseq_sync/spec/effect_runner/dune`.
- `logseq_sync/lib/effect_runner/dune`.
- `logseq_sync/test/dune`.
- `logseq_sync.opam` and `logseq_sync.opam.locked`.
- `logseq_db_worker/contract/dune`.
- `logseq_db_worker/spec/pure_reducer/dune`.
- `logseq_db_worker/lib/pure_reducer/dune`.
- `logseq_db_worker/spec/effect_runner/dune`.
- `logseq_db_worker/lib/effect_runner/dune`.
- `logseq_db_worker/lib/dune`.
- `logseq_db_worker/bonsai/dune`.
- `logseq_db_worker/test/dune`.
- `logseq_db_worker/tool/dune`.
- `logseq_db_worker.opam` and `logseq_db_worker.opam.locked`.
- `app/dune`.
- `test/dune`.
- `logseq_journal.opam` and `logseq_journal.opam.locked`.

Execution steps:

1. Confirm the final dependency graph is `logseq_db_types -> logseq_db_storage -> logseq_overlay_db -> logseq_sync -> logseq_db_worker -> app`, with Worker also depending directly on overlay for its request boundary.
2. Keep the virtual public library dependency-light and place Datascript, storage, and codec dependencies only in the default implementation.
3. Run `opam lock ./logseq_db_types.opam`, `opam lock ./logseq_db_storage.opam`, `opam lock ./logseq_overlay_db.opam`, `opam lock ./logseq_sync.opam`, `opam lock ./logseq_db_worker.opam`, and `opam lock ./logseq_journal.opam`, then commit all generated lock files.
4. Run `dune build logseq_overlay_db.install` in the workspace so Dune builds the exact local `logseq_db_types` and `logseq_db_storage` dependencies, then verify the install manifest exposes only `Logseq_overlay_db.Types` and `Logseq_overlay_db.Database` from the virtual library.
5. In a clean CI opam switch, install `./logseq_db_types.opam` and `./logseq_db_storage.opam`, install the dependencies of `./logseq_overlay_db.opam`, and only then run `dune build -p logseq_overlay_db @install` to prove the package does not rely on hidden workspace modules or stale installed dependencies.
6. Run `dune exec logseq_overlay_db/test/test_overlay_reads.exe`.
7. Run `dune exec logseq_overlay_db/test/test_overlay_mutations.exe`.
8. Run `dune exec logseq_overlay_db/test/test_overlay_changes.exe`.
9. Run `dune exec logseq_overlay_db/test/test_overlay_sync.exe`.
10. Run `dune exec logseq_overlay_db/test/test_overlay_storage.exe`.
11. Run `dune exec logseq_overlay_db/test/test_overlay_concurrency.exe`.
12. Run `./logseq_overlay_db/tool/test_performance.sh` so it builds the release profile, measures every declared outbox size including the configured maximum, and enforces the p95 and retained-memory thresholds.
13. Run `dune exec logseq_db_worker/test/test_protocol.exe`.
14. Run `dune exec logseq_db_worker/test/test_pure_reducer.exe`.
15. Run `dune exec logseq_db_worker/test/test_effect_runner.exe`.
16. Run `dune exec logseq_db_worker/test/test_overlay_integration.exe`.
17. Run `dune exec logseq_db_worker/test/test_bonsai_service.exe`.
18. Run `dune exec logseq_sync/test/test_sync.exe`.
19. Run `dune build @logseq_db_worker/test/managed-sync-online-e2e` with the dedicated credentials and verify the deployed stale-basis, frozen-request retry-to-Stale, normalized Pull, and delete-conflict ordering contract still passes after cutover.
20. Run `dune exec test/application_view_test.exe`.
21. Run `dune exec test/logseq_db_worker_application_integration_test.exe`.
22. Run `dune exec test/logseq_overlay_db_boundary_test.exe -- "$PWD" _build/default/logseq_overlay_db.install` and verify package-local public and private-module boundaries.
23. Run `dune exec test/source_boundary_test.exe -- "$PWD" _build/default/logseq_sync.install _build/default/logseq_overlay_db.install` and reject references to private overlay modules, decoded Datascript types, entity IDs, projected connections, durable outbox encodings, and obsolete Worker or Sync data-plane modules.
24. Run `dune fmt` and inspect every resulting diff before final builds and tests.
25. Run `dune build @all`.
26. Run `dune runtest`.
27. Run `spec-dev-tool check docs/agent-guide/exploring/architecture/2026-09-01-logseq-overlay-db-package.md`.
28. Run `spec-dev-tool check --all`.
29. Run `git diff --check` and inspect `git status --short`.

Source-boundary assertions:

- Only the overlay implementation may depend on authoritative Datascript handles and encoded outbox storage.
- Storage receipt APIs may expose only namespace-safe fixed-size opaque keys and opaque bytes and may not import overlay modules; overlay alone maps mutation UUIDs and submission-batch IDs into those key namespaces.
- No public overlay spec may mention Datascript, entity IDs, transaction operations, SQLite rows, or encoded outbox records.
- No public overlay or Worker operation catalog may retain a read or mutation constructor outside the confirmed current-App surface.
- Public remote-won receipts and rejected-delete catch-up descriptors may expose identities, closed reasons, conflict kinds, required catch-up cursors, and retry eligibility, but never rollback windows, wire bytes, or decoded transaction facts.
- Sync may depend only on typed overlay Sync access and its own transport and cryptography modules.
- Worker may depend only on the public overlay database interface, the public Sync interface, and its UI protocol modules.
- The app and OCaml UI domain may depend only on Worker-facing interfaces.

## Alternatives considered

### Retained materialized projected Datascript connection

This makes reads and Datascript listeners convenient, but it keeps a second graph-sized Datascript database in memory and introduces cache reconstruction and consistency responsibilities.

The proposal rejects this option because the projected state must remain a logical composition rather than a retained cache.

### Replay the complete outbox into a temporary Datascript database for every read

This avoids a retained second database, but point reads allocate and transact a graph-sized temporary value and make cost depend on the authoritative graph rather than the requested records.

The proposal instead overlays indexed field and structure effects only for the requested UUIDs and scopes.

### Union authoritative and outbox listener results

A simple union can emit duplicate changes, transport-only changes, and temporary disappearance when an accepted mutation moves from outbox to authoritative storage.

The proposal merges source fragments by package commit and compares logical before and after state.

### Store complete optimistic block snapshots in the outbox

Complete snapshots simplify some point reads, but they overwrite unrelated remote field changes and cannot faithfully represent structure, reverse dependencies, or field ownership.

The proposal stores semantic intent plus normalized field-level and structure-level logical effects.

### Expose Datascript entity IDs as public identities

Entity IDs are database-instance-local and can change across import, restore, compaction, or reconstruction.

The proposal uses `block/uuid` and page UUIDs at every public and durable boundary.

### Keep a conflicted delete active and promote new descendants to the page root

This preserves immutable Submitted tombstones, but it still deletes the original subtree, invents a new structure for remote descendants, and ignores the delete's external reference, title, metadata, comment, and property-holder write footprint.

The proposal rejects it because remote-wins requires deactivating the complete optimistic delete, while the exact conditional barrier must prevent any causally-stale hard delete from reaching authoritative storage.

### Keep a thin Worker `Engine` facade over the new package

A compatibility facade would leave two apparent owners for snapshots, reads, mutations, and lifecycle, and it would preserve obsolete call paths.

The proposal deletes `Engine` and updates all callers in one cutover.

## Acceptance criteria

- `logseq_overlay_db` is an independently buildable and installable opam package.
- `logseq_overlay_db/spec/` defines the canonical virtual public interfaces and the implementation satisfies them.
- No public type exposes a Datascript database, connection, entity ID, decoded transaction operation, SQLite row, or durable encoded outbox record.
- The only encoded transaction boundary is an input-only, bounded, protocol-neutral wire value that is immediately wrapped as an opaque validated type.
- Every read uses an active immutable snapshot lease that pins one authoritative root, one logical-outbox root, and their coherent versions until explicit release.
- Public snapshot and graph-info versions contain only generation and projection revision, so masked authoritative or transport metadata changes cannot silently alter a public logical read without a projection event.
- Dynamic used outbox capacity, protected-wire bytes, and retained origin-evidence bytes are available only through `inspect_admission`, which is outside snapshot, projection-revision, and listener semantics.
- No retained materialized projected Datascript database, projected connection, or graph-sized overlay cache exists.
- `Storage_session` retains physical addresses and metadata rather than a second long-lived EAVT/AEVT/AVET root set, and compaction uses short-lived bounded-path handles.
- Overlay auxiliary memory is proportional to the bounded active outbox plus active snapshots, listeners, and result size.
- The durable outbox contains deterministic semantic intents and indexed field, structure, tombstone, reverse-dependency, frozen delete-frontier, write-footprint, conflict-guard, rollback-window, and origin-evidence data.
- Incorporated mutation IDs move atomically to durable receipts, and idempotency survives acknowledgement and restart.
- Queued ordinary effects are replannable, while every committed delete artifact and every Submitted or Accepted payload is frozen; a remote-conflicted delete is resolved only through the exact conditional-barrier paths defined by the state matrix.
- The confirmed current-App mutation planners read the logical overlay and support pending-on-pending operations.
- Semantic mutations contain no Datascript basis, and unrelated authoritative or transport changes do not invalidate a prepared local write whose complete logical read set is unchanged.
- Public and durable identities use block and page UUIDs only.
- The package supplies only the current App's public graph-information, journal listing, explicit page, explicit block, immediate-child, and bounded-page-tree reads.
- Journal-list results retain page revisions and projection-bound date/UUID cursors; matching `Journal_index_interest` changes discover unknown journal insertions and pagination changes without a graph-wide refresh.
- Local save, insert, delete, journal-create, and task-status effects compose correctly with authoritative data, while authoritative moves, reorders, page metadata, references, tags, properties, and task state remain correctly readable without corresponding unused public local operations.
- Every delete freezes a bounded frontier, complete write footprint, conflict guard, and rollback window before submission, and its semantic UUID set and protected wire never dynamically include a remote descendant.
- The deployed server atomically compare-and-appends each singleton delete only at its frozen `t_before`; an intervening transaction produces a batch-level Stale non-execution response, and implementation stops before enabling delete if that invariant or the normalized Pull plus separate-`outliner-op` contract cannot be proven online.
- A causally-prior remote delete conflict deactivates the complete optimistic delete, emits at most one exact or resync rollback event only when canonical logical before and after differ, never promotes a descendant to an invented root, and terminates as `Remote_won Before_submission` or `Remote_won Proven_unexecuted` without forward compensation.
- Conflict classification uses validated server cursor intervals plus exact simulated normalized datom multisets at each cursor's `db-before`, so ACK-before-Pull, Pull-before-ACK, rejection-before-Pull, and Pull-before-rejection produce the same final logical result and own incorporation never self-conflicts.
- The conflict window has a closed two-case server boundary: it ends immediately before an accepted own delete's incorporation cursor, or inclusively at a rejected delete's validated Stale `through` cursor; it never ends merely when the client receives a callback, and every proven-Remote transaction after the applicable boundary is ordinary later authoritative state that cannot trigger whole-delete undo.
- One package transition emits either zero or one ordered logical projection event.
- Every event reserves bounded dispatcher capacity before durability, and lagging subscribers coalesce to an explicit resync.
- Transport-only state transitions emit no projection event.
- Equivalent authoritative acknowledgement does not make a block disappear and reappear.
- Authoritative data, checkpoint, outbox lifecycle, and mutation receipts commit atomically.
- All ordinary validation and Datascript transaction failures occur before durable commit.
- Restart reconstructs the same logical state from durable authoritative, outbox, and mutation-receipt state.
- Close rejects new work, invalidates leases and prepared handles, drains or resyncs committed notifications, waits for in-flight calls, and releases storage deterministically.
- A post-commit publication failure reopens with a fresh generation and forces interested-state rehydration.
- Public mirror, snapshot activation, deletion, garbage collection, and crypto bridge APIs are usable without private-module imports.
- E2EE uses only opaque correlated preparation, protection, unprotection, and commit tokens across the overlay and Sync boundary.
- Sync owns no outbox codec, authoritative checksum implementation, raw Datascript DB input, or decoded authoritative transaction path beyond the bounded opaque wire ingress required for transport and crypto.
- Worker owns no engine, logical read model, mutation planner, authoritative mirror, snapshot parser, or storage transaction path.
- The UI receives UUID-scoped changes only through Worker, refetches only interested logical records, and updates only affected Bonsai fragments; remote-wins windows include the frozen footprint, new guard entities, reverse dependents, and affected page or structure scopes, with bounded overflow represented only by resync.
- All new unit, property, model-based, concurrency, integration, performance, and source-boundary tests pass.
- Obsolete projected-DB, entity-ID, compatibility, duplicate data-plane, and unused Worker read or mutation paths are deleted without replacement.

## Implementation evidence

- `logseq_overlay_db` now owns the authoritative Datascript connection, durable queryable outbox, mutation receipts, immutable logical snapshot leases, UUID-addressed reads and mutation planning, authoritative transitions, crypto correlation, mirror lifecycle, and the merged logical change dispatcher behind the public `Types` and `Database` virtual-library modules.
- Sync consumes the typed overlay submission and authoritative-ingress capabilities, while Worker delegates graph data-plane effects to overlay. The former Worker engine, planners, read model, projected connection, mirror, snapshot parser, storage transaction paths, duplicate Sync codecs, and obsolete v1 protocol fixtures are deleted without compatibility aliases.
- Origin classification simulates each accepted member against its exact authoritative `db-before` and compares normalized datom multisets at the expected cursor. Pull retains the server-normalized transaction report and separate `outliner-op`; it does not depend on a persisted or echoed `tx-id`.
- The deployed managed-sync E2E proves Worker insert and delete, exact `t_before` compare-and-append, retry-to-`Stale`, normalized Pull, singleton delete ordering, and batch-level stale-delete non-execution. Local block order values also pass an independent implementation of Logseq's base62 fractional-index validation and are accepted by the deployed service.
- The overlay suites cover reads, mutations, storage and restart recovery, listener changes, deterministic Sync arrival orders, delete conflict windows, model-based projection equivalence, concurrency, and bounded performance over the 100,000-block fixture and every admitted outbox size.
- A clean OCaml 5.1.1 switch installs the repository's current `logseq_db_types` and `logseq_db_storage`, resolves the pinned Datascript, Transit, EDN, and persistent-set dependencies, and builds `dune build -p logseq_overlay_db @install` without workspace-private modules or stale installed packages.
- `dune fmt`, `dune build @all`, `dune runtest`, the release performance gate, package and source-boundary tests, six opam lint checks, `git diff --check`, the proposal check, and `spec-dev-tool check --all` pass.

## Consequences

- Graph storage, optimistic projection, mutation planning, receipts, authoritative incorporation, and logical change publication now have one owner below Sync and Worker. Callers use UUID-scoped overlay contracts and cannot reach Datascript connections, entity IDs, SQLite rows, or durable outbox encodings.
- Logical reads no longer require a second graph-sized Datascript database. Their work and retained auxiliary memory are bounded by the requested result, active outbox, leases, and listeners, at the cost of maintaining explicit field, structure, reverse-dependency, tombstone, guard, and rollback indexes.
- Sync retries preserve frozen bytes and the original conditional cursor, but the deployed server provides no mutation-ID deduplication. A retry may execute only while `t_before` remains current; otherwise it terminates as `Stale` and requires authoritative catch-up.
- Delete remote-wins behavior depends on frozen singleton submissions, exact cursor intervals, normalized-datom origin evidence, and batch-level non-execution proof. Ambiguous evidence pauses progress rather than guessing from callback arrival order.
- Worker and App code are smaller and update only interested UUID-scoped fragments, while removed Engine, projected-database, legacy protocol, and unused operation paths are intentionally unavailable with no migration or compatibility layer.
- The new package adds a separately installable opam boundary and requires its pinned sibling Transit and EDN packages to remain complete so clean-switch builds do not accidentally use stale workspace installations.

## Risks

- An incomplete overlay field or reverse-dependency model can return internally inconsistent logical records.
- Field-level patches require explicit ownership and conflict semantics for every supported attribute.
- The current outbox limit of 4,096 records or 8 MiB may still make wide queries expensive even though it is much smaller than the authoritative graph.
- A durable receipt per incorporated mutation grows storage over time, and the first cutover accepts that cost because safe compaction requires an explicit no-ID-reuse boundary.
- Moving mutation planning out of Worker is the largest ownership-boundary change and can reveal hidden dependencies on raw Datascript indexes.
- Capturing authoritative and outbox roots separately without one execution lane would permit torn snapshots.
- An ambiguous commit-identifier source would make authoritative and outbox listener merging nondeterministic.
- A slow or reentrant listener can stall fan-out unless callbacks are isolated from the transition lane.
- Dispatcher reservation and slow-subscriber resync must be proven not to deadlock close or concurrent commits.
- A delete write footprint can be much larger than its visible subtree because references, comments, titles, timestamps, metadata, and property holders also require guard and rollback coverage.
- A large delete can exceed bounded frontier, footprint, guard, or rollback-window admission and must fail before publishing its local effect.
- Datascript `RetractEntity` cascades across incoming refs, so loss of the exact server conditional barrier would make bounded remote-wins impossible; this is a deployment blocker, not a recoverable local compensation case.
- Frozen Submitted non-delete effects may temporarily compose awkwardly with a conflicting remote reorder, but changing already-sent bytes would violate transport idempotency.
- Remote-wins correctness depends on singleton delete attribution, transaction-ordinal staging, exact frozen-member simulation, exact `t_before` compare-and-append, and batch-level Stale non-execution evidence; the deployed server provides no mutation-ID idempotency.
- An overlapping Pull without sufficient semantic or transport evidence must remain bounded and paused, and a rejection-first delete must durably retain its catch-up cursor, or message arrival order could misclassify the package's own delete as a remote conflict.
- A blocked mutation can invalidate later dependent mutations, so suffix-blocking rules must be explicit and deterministic.
- The new outbox encoding intentionally has no migration or compatibility layer, so rollout must replace obsolete durable development data or use a coordinated storage reset.
- Temporary candidate authoritative Datascript values can briefly increase peak memory during large remote batches even without a retained projected database.
- Tail compaction can temporarily retain touched physical index paths, so its tail threshold, node-cache lifetime, and peak allocation require explicit gates even though no second physical index root remains long-lived.
- A process failure after durable commit but before in-memory publication relies on restart reconstruction, a fresh generation, and mandatory interested-state rehydration.
- Incorrect package dependencies can create a cycle among storage, overlay, Sync, and Worker.

## Testing Details

`NOTE: I will write *all* tests before I add any implementation behavior.`

The RED phase creates every executable, fixture, naive model oracle, concurrency harness, performance harness, and source-boundary assertion before production behavior is added.

Each RED test must compile and fail through an assertion that names the missing behavior rather than through an unhandled exception or setup error.

The GREEN phase proceeds in dependency order from the queryable outbox, through logical reads and planning, to transitions, Sync, Worker, and app integration.

The model-based suite compares public overlay results and change events against a deliberately simple full-replay oracle over generated authoritative states and ordered outbox intents.

The concurrency suite controls transition barriers so interleavings are reproducible and verifies snapshot coherence, event ordering, listener reentrancy, and close behavior.

The performance suite records wall time, allocations, retained memory, and authoritative index accesses for point reads, journal reads, structure reads, local commits, authoritative acknowledgement, rebase, reopen, and listener diffing on the 100,000-block fixture at both ordinary and maximum outbox admission.

The performance gate rejects any point operation whose cost or retained auxiliary memory grows with total authoritative graph size when requested result size and active outbox size are fixed.

The final verification reruns package tests, Worker tests, Sync tests, app integration tests, repository-wide tests, formatting, documentation checks, and source-boundary checks.

## Implementation Details

- Treat `Projection(A, O)` as a logical value and retain only the one authoritative Datascript connection.
- Use UUID-indexed field, structure, tombstone, reverse-dependency, bounded delete-frontier, conflict-guard, and rollback-window effects so logical work is bounded by requested data and active outbox size.
- Pin coherent roots and revisions in explicitly releasable snapshot leases and compute target-state digests on demand.
- Validate local commits against the complete logical planner read set rather than a global Datascript basis.
- Replan only never-submitted ordinary queued effects, freeze every committed delete artifact and submitted byte, retain rejection-first delete state through authoritative catch-up, and compact remote-conflicted deletes only with terminal non-execution evidence.
- Serialize transitions through one lane, merge private authoritative and outbox listeners by commit ID, and reserve bounded event capacity before durability.
- Compare logical before and after state and emit at most one exact or resync event per package commit.
- Keep Sync responsible for transport and cryptography while overlay owns durable data, crypto correlation, mirror lifecycle, and state transitions.
- Keep Worker responsible for v2 UI change windows while the UI hydrates and replaces only interested normalized fragments.
- Keep public types implementation-independent, expose only the confirmed current-App operations, and delete every superseded or unused module, dependency, fixture, and compatibility path during GREEN cutover.

## Questions

None.

The current-App-only cutover, opaque E2EE token boundary, causally bounded remote-wins subtree-delete semantics, canonical Sync and Worker specification edits, and required Dune and opam edits are all confirmed decisions.

---
