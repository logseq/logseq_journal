# Overlay API Call-Local Read Reuse

## Problem

Several public overlay database operations repeatedly read metadata or rebuild
logical records while processing one request. These costs belong to
`logseq_overlay_db` and can be reduced without changing third-party libraries or
moving database ownership into another layer.

The user selected five findings for this proposal:

1. Repeated enumeration of `db/ident` and repeated property-definition reads.
2. Repeated block, subtree, and affected-page reads during deletion admission.
3. Duplicate sibling scans for insertion precondition validation and order
   assignment, including unnecessary full entity reads.
4. Metadata enumeration for an empty `Database.get_blocks` request.
5. Repeated metadata reads across one `Database.get_pages` batch.

The 2026-09-07 audit used source commit
`b32baf08ef0503cc84ab5df613607b058efa9e59` and a constructed graph with 100,000
blocks and 504,455 live authoritative datoms. Its baseline started with an empty
outbox and applied mutations sequentially. The insertion target had 256 direct
children; deletion targeted the just-inserted ten-block overlay tree.

| Operation | Consumed datom results | Relevant measured repetition |
| --- | ---: | --- |
| `get_blocks []` | 173 | One unnecessary ident enumeration |
| `get_blocks`, one existing block | 222 | Includes the 173-ident catalog |
| `get_blocks`, 64 blocks | 600 | Existing batch-local hydration reuse |
| `get_pages`, 64 pages | 1,408 | Repeated metadata lookups across pages |
| `commit_local`, insert ten blocks | 3,266 | Two sibling scans: 2,562 entity results and 512 parent-index results |
| `commit_local`, delete ten blocks | 7,920 | 33 ident enumerations, totaling 5,709 results |

Insertion reads the same sibling group once to validate the Children revision
and again to find the maximum order. Deletion repeatedly reconstructs records
while checking the root, walking children, collecting affected pages, and
assembling its footprint. Without a supplied cache, `logical_block_at` calls
`block_of_database`, which creates a new hydration cache before checking whether
the block exists in the authoritative root. This also affects blocks that exist
only in the overlay.

Counts include repeated consumption of the same datom, not distinct graph
facts. They measure instrumented datom access boundaries, not every internal
Datascript index comparison or physical SQLite page read. They exclude the
caller's earlier reads used to construct write preconditions. The historical
measurements are evidence, not unverified performance gates for a later checkout.

The complete original audit and raw measurements are available in the local
[audit report](/Users/rcmerci/.codex/visualizations/2026/09/07/01a07be1-bc10-7c10-a1ba-c51d7f049246/overlay-db-audit/report.md)
and [measurement data](/Users/rcmerci/.codex/visualizations/2026/09/07/01a07be1-bc10-7c10-a1ba-c51d7f049246/overlay-db-audit/raw-measurements.jsonl).
The table above preserves the relevant baseline independently of those local
artifact paths.

## Decision

### Fixed scope and user requirements

Apply the five selected reductions as one internal read-reuse change. The
user explicitly requires every newly introduced cache to live within one public
overlay-db API invocation. This is a hard constraint, not an optional design
alternative.

The user confirmed the scope and call-local cache lifetime on 2026-09-07 and
requested transition to proposed. Implementation was subsequently authorized
and completed on 2026-09-08. The execution evidence below records the verified
result and remaining allocation tradeoff.

The scope excludes selective queued replan, persistent structural indexes,
cross-request pagination reuse, snapshot checksum redesign, outbox persistence,
tail persistence, and mutation coalescing. Existing callers may benefit from
shared helper improvements, but this work must not expand into those separate
algorithms or change their semantics.

### Cache lifetime: one public API invocation only

Any added cache or memoized result must follow all of these rules:

- Allocate it inside the invocation that uses it, after acquiring the appropriate
  read lease or serialized mutation state. Construct it lazily where possible.
- Pass it explicitly through internal helpers. Reuse is allowed between helper
  calls participating in that same public invocation.
- Do not store it on `Database.t`, a snapshot lease, an outbox record, a
  subscription, a prepared transition, a crypto request, a module-level table,
  or any other object that survives the invocation.
- Do not retain it in dispatched events, callbacks, detached fibers, lazy
  results, or closures that escape the invocation. Public results must not
  capture the context or its retained roots. If an existing serial dispatch
  wrapper awaits completion, end cache reachability at the computation boundary
  rather than attaching the cache to the dispatched work.
- A second call using the same snapshot must create its own context. Two calls
  in one Eio switch, one application workflow, or one sync cycle are still two
  independent cache lifetimes.
- `begin_*` and `apply_*` are separate invocations. A preparation or crypto
  handoff must not carry this optimization's cache between them.
- If public APIs invoke other public APIs, each invocation keeps its own cache
  boundary; share through internal helpers instead of introducing a hidden
  cross-API cache parameter.
- Success, typed error, exception, and cancellation must all end ownership of
  the context. No explicit GC collection is required, but no escaping reference
  may keep it or its captured roots alive after the call completes.

This constraint supersedes the optional cross-request cache follow-up discussed
in the earlier
[Page_tree decision](../../implemented/bugfix/2026-09-07-page-tree-bounded-reads-without-scope-revision.md)
for the work covered by this document. Do not edit that historical document or
implement its optional shared-cache path as part of this proposal.

### State identity within an invocation

A call-local lifetime alone does not make every cached answer valid throughout
the call. An authoritative root and a logical overlay view are different inputs.

Use an internal call-local read context separating:

- Authoritative metadata: ident resolution, property definitions, reference
  UUIDs, and authoritative entity fields, bound to one immutable Datascript root.
- Logical results: block/page records, their missing results, derived revisions,
  and sibling facts, bound to one exact authoritative-plus-overlay view.

Do not key logical results by UUID alone if the context can encounter different
views. Before/after snapshots, a changed outbox prefix, or a candidate mutation
must use separate logical caches, or explicitly recreate the context when the
view changes. Mutable outbox-record identity is not evidence that its content
has remained unchanged. Use separate contexts instead of a new global versioning or invalidation
mechanism. Extend the existing hydration helpers with explicitly passed
call-local memo tables where needed; the exact record layout is an internal
implementation choice subject to the lifetime and state-identity constraints.

Cache missing results distinctly from entries that have not been loaded, so
an authoritative miss for an overlay-only block does not trigger repeated work.
Never treat an authoritative miss as proof of a logical miss: active overlay
insertions and dependency shadows still participate in logical reconstruction.

For local admission, reuse the pre-mutation view across precondition checks and
planning only while it remains unchanged under the existing serialization. Do
not reuse that view's logical results after publishing the candidate outbox.

### Metadata and deletion reuse

Thread the same internal context through the selected operation's metadata,
property, logical block/page, and deletion helpers. Prefer extending the existing
hydration helpers rather than adding a parallel uncached implementation.

During one deletion admission:

1. Validate the required root revision using the captured logical view.
2. Enumerate and freeze the latest logical subtree under the existing serialized
   admission boundary.
3. Reuse the resulting records when collecting affected pages, parent scopes,
   incoming-reference patches, and the final effect footprint.
4. Reuse property definitions and UUID resolutions while reconstructing local
   inserted blocks and resolving property/default-value deletion behavior.

Preserve comments-area handling, incoming-reference title replacement,
default-property guards and holder patches, deterministic ordering, and all
existing admission limits. Reduce duplicated reads without removing required
checks, changing the frozen footprint, or reading a subtree from an earlier API
invocation. Root-only delete preconditions and later synchronization conflict
semantics remain unchanged.

### Insertion: share structural facts, not full records

The Children revision check and insertion order assignment must consume one
shared sibling-fact result for the same parent and logical view. Retain the
current authoritative/local merge, tombstone handling, UUID deduplication,
order comparison, and membership digest inputs.

Read the parent index and the UUID/order fields needed by these consumers.
Establish the existing helper's eligibility behavior before reducing fields;
additional data is permitted only where required to preserve that behavior.
Do not hydrate complete sibling records or property summaries solely to compute
a membership digest or maximum order.

Reuse the scan for the mutation parent even if the caller supplies additional
valid preconditions. Other precondition scopes must still be checked. Collect
membership information and the maximum order together where feasible, avoiding
a second retained copy of the same sibling collection.

This removes duplicate work but does not make insertion independent of sibling
count: validating the current Children digest still requires reading sibling
facts. A first-call persistent order index or incrementally stored digest is
outside this scope.

### Empty block requests and batched page reads

For `get_blocks []`, preserve the existing `with_snapshot_read` lifecycle and
error validation before returning `Ok []`. Do not allocate or enumerate a
hydration cache. A released snapshot or closed database must not become valid
merely because the request is empty.

For `get_pages`, allocate one lazy call-local metadata context for the whole
batch and pass it through logical page reconstruction. Preserve input order,
duplicate requests, missing-page revisions, page classification, property
summaries, recycling state, and pending overlay visibility. Cache immutable
property definitions separately from per-page property values; values belonging
to one page must never leak into another page's result.

### Ownership and implementation boundary

Likely production touch points are internal helpers in
`logseq_overlay_db/lib/database.ml`:

- `hydration_cache`, property-definition/summary helpers, and UUID resolution.
- `logical_block_at`, `logical_page_at`, `get_blocks`, and `get_pages`.
- `preconditions_match`, `revision_for_scope`, and structural child-fact helpers.
- `insertion_orders`, `local_candidate_record`, `planned_effect`, and deletion
  artifact construction.

Use private overlay helper modules only if justified by the existing structure.
No changes to `logseq_db_storage`, Datascript, persistent-sorted-set, Worker/App
contracts, or public `spec/*.mli` interfaces are expected. Do not modify Dune
files, OCaml files under `spec/`, or OCaml files in bonsai_flutter. If the public
spec proves insufficient or unclear during development, stop and report the
specific issue, suggested spec change, and rationale.

No user-facing flow or UI change is proposed. Existing behavior required by
`docs/ux-guidelines.md` remains intact. Remove superseded internal paths rather
than adding compatibility wrappers or persistent-cache fallback modes.

## Alternatives considered

### Database-owned or snapshot-owned cache

Rejected by the explicit user requirement. Even a bounded, version-keyed cache
on an immutable snapshot can live across multiple API calls. LRU eviction or
weak references do not make it call-local.

### One call-local cache shared across changing logical views

Rejected because short lifetime is not sufficient for correctness. A UUID can
resolve differently before and after a local or authoritative transition within
one invocation. Separate logical contexts are required when the view changes.

### Remove repeated validation instead of reusing its inputs

Rejected. Children membership validation and root-block preconditions are
observable concurrency guarantees. Deletion must freeze the latest admitted
subtree and preserve reference/property cleanup.

### Keep full sibling hydration and only cache the second scan

This can remove one pass but retains unnecessary full-record reads and memory.
Prefer shared structural facts containing only what validation and ordering
need, subject to preserving existing eligibility behavior.

### Add a persistent structural index in the same change

Deferred as a different design with different ownership and update costs. The
selected scope does not require O(limit) first reads or cross-call pagination
reuse and does not authorize persistent caches.

## Acceptance criteria

### Behavior and lifetime

- Every new cache is created, used, and released within one public API
  invocation. No cache is reachable through database/snapshot/preparation state,
  returned values, or asynchronous notifications after the invocation ends.
- Repeated calls on the same snapshot do not reuse this change's caches. Existing
  Datascript/SQLite internal caching is outside this constraint and is not
  changed or represented as an overlay-owned cache.
- Concurrent calls use independent contexts. An old snapshot remains coherent
  after later writes, and cached missing results do not hide later insertions
  when a fresh snapshot or logical view is read.
- Root identity and logical-view identity are respected within each invocation;
  before/after content, local page titles, task status, and property values never
  cross-contaminate cached answers.
- Results, revisions, ordering, typed errors, precondition conflicts, mutation
  identities, normalized transactions, delete artifacts, and notifications
  retain their current semantics.
- Empty block requests consume zero graph datom results after the existing
  snapshot validation; invalid lifecycle states retain their previous errors.

### Measured work

- Re-establish the baseline on the implementation checkout through public APIs.
  Retain before/after input identities and the exact instrumentation contract.
- Within each selected invocation and immutable authoritative root, ident
  enumeration occurs at most once if used at all. Property definitions and
  missing definitions are not reread for every entity that uses the same ident.
- During deletion, each required logical block is constructed at most once per
  unchanged logical view and reused across planning phases. Metadata work must
  not grow by one full catalog scan per block or phase.
- In insertion admission, the target parent's authoritative sibling enumeration
  occurs once and supplies both Children revision validation and order
  assignment. Full sibling payload/property hydration is not performed solely
  for those consumers.
- Page-batch property-definition work is proportional to distinct required
  definitions, rather than multiplying the same metadata reads by page count.
- Rerun the 100,000-block fixture for the selected APIs and record total consumed
  datoms, reads by attribute/index, ident enumerations, logical record builds,
  allocations, and peak memory where practical. Keep physical storage reads and
  non-instrumented timing samples separate from logical counters.
- Compare two identical calls on the same snapshot: internal work is reused
  within each call, but the second call must not gain cross-call overlay-cache
  hits. Physical index caches may still change disk-read counts.
- Include authoritative and overlay-only deleted trees, repeated/absent UUIDs,
  distinct property values sharing a definition, changed page titles, rich
  properties, interleaved entity IDs, wide parents, and stale preconditions.
  Select focused cases according to their actual ownership boundary rather than
  duplicating a complete scenario matrix across layers.
- Report remaining O(sibling count) structural work and required reference
  fanout honestly. Do not promise a fixed post-change datom total before the
  implementation has been measured.

### Regression ownership and verification

Before adding any bug regression test, identify the production state owner and
attempt reproduction through public pure reducer events, completions, state,
and effects. The expected owner for these read counts is Database, but this
must be established rather than assumed. A reducer completion containing an
already-computed expensive or incorrect result does not reproduce its cause.

If the pure reducer boundary reproduces the defect, add only pure reducer
regressions. Otherwise document the missing ownership boundary and use the
narrowest public layer executing the repeated reads. Do not bypass `.mli`
interfaces, copy production logic into tests, move ownership for test
classification, remove existing tests, or duplicate coverage in effect runners,
transport, persistence, integration, E2E, and UI layers.

A shared request to Worker can explain routing, but does not by itself measure
Database traversal or cache lifetime. Use deterministic public API access
probes for the latter, with instrumentation that preserves observable behavior.
Use existing build/test declarations. Run affected overlay tests, the complete
overlay suite, relevant access probes, and `spec-dev-tool check --all` when
implementation is later authorized.

## Consequences

- Passing a cache through only some reconstruction helpers can leave most
  property reads duplicated, especially for overlay-only blocks.
- Caching a metadata definition together with entity-specific values can leak
  one block/page's values into another result.
- A call-local context can still read stale data after a view change, or escape
  accidentally through a lazy sequence or callback.
- Retaining every intermediate collection can reduce reads while increasing
  peak memory. Reuse existing records/facts rather than maintaining redundant
  full subtree and sibling copies; retain existing admission/response limits.
- Reducing structural fields can accidentally change handling of malformed
  entities or order ties. Existing behavior must be established first.
- Cross-call work is intentionally not optimized by this proposal. Repeated
  pagination calls and separate precondition-fetch/commit calls may still read
  the same facts again.
- Removing every redundant scan may require threading an internal context
  through several helpers. Avoid solving that plumbing with global state,
  broad new ownership objects, or an unrelated module reorganization.


## Implementation evidence

Implemented on 2026-09-08 in `logseq_overlay_db/lib/database.ml`:

- `read_context` captures one logical view inside the snapshot lease or serialized
  admission computation. Lazy metadata, explicit missing results, authoritative
  entity/UUID/presence tables, and logical record tables remain call-local.
- Page batches and block requests share metadata and logical records. Empty block
  requests retain lifecycle validation and perform zero datom reads.
- Admission preconditions, deletion planning, reference/default-property cleanup,
  affected scopes, and logical-effect checks reuse the pre-mutation view.
- Insertion shares one sibling digest/maximum summary per parent. Bounded EAVT
  field reads preserve the exactly-one-value eligibility rule without full
  sibling payload hydration. Shadow eligibility shares the production block
  header validator. Superseded revision and duplicate-scan paths were removed.

The public reducer reproduction attempt established Database as the read-work
owner. Public API probes use isolated instrumentation and existing build
artifacts; no public spec, Dune, storage, or third-party source was changed.
The pre-existing Rrbvec worktree edits were preserved.

The 100,000-block fixture retained its 504,455-datom identity. Consumed datoms
changed from 173 to 0 for empty blocks, 1,408 to 337 for 64 pages, 3,266 to 1,043
for ten inserted blocks, and 7,920 to 53 for ten deleted overlay-only blocks.
Deletion constructed each required logical block once. Repeated calls consumed
the same logical work independently. Weak-reference probes confirmed that
metadata, read contexts, and structural-reader closures do not escape completed
calls. All 22 public result digests, prepared plaintexts, and submitted wires
matched the baseline.

Validation passed: affected read/mutation tests, all 182 overlay tests,
`dune build @all`, `dune runtest`, access/lifetime probes, separate plain timing
runs, changed-source formatting, and the full agent-document check.

The remaining O(sibling count) structural work and reference fanout are not
removed. In the wide-parent case, plain cumulative allocation increased from
255,154 KiB to 708,814 KiB; the one-shot timing changed from 196.049 ms to
209.924 ms. This is an explicit tradeoff, not a claim that fewer consumed datoms
improve every allocation or latency measure. No persistent index or cross-call
cache was added to hide that cost.

See the [verification report](../../../test-reports/2026-09-08-overlay-read-reuse/README.md)
for the ownership attempt, complete before/after counters, exact source and
fixture identities, semantic cases, lifetime audit, measurements, and logs.
