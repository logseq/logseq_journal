# Page Tree Bounded Reads Without Scope Revision

## Problem

`Database.get_structure (Page_tree ...)` currently materializes every logical
block within the requested depth before applying the cursor offset and limit.
It then traverses the same structure again in `revision_for_scope` to compute a
page-tree scope digest. The second traversal calls `logical_block_at` without
the shared hydration cache, rebuilding property metadata for individual blocks.

The prior offline access audit measured identical work for limits 1 and 200 on
the selected large journal:

| Requested depth | Consumed datom results | Datom API calls | Full `db/ident` enumerations |
| --- | ---: | ---: | ---: |
| 1 | 38,773 | 17,220 | 82 |
| 64 | 128,517 | 57,753 | 270 |

The mirror contained 242 ident rows. At depth 64, repeated ident enumeration
alone consumed 65,340 results. These are historical instrumented measurements,
including repeated consumption; they are not unique datom counts, disk-read
counts, or a new benchmark of the current checkout.

The App uses depth 1 for timeline loading, loading older days, continuation
within a day, refreshing after capture/save/status/child insertion, and
reconciling registered page-tree interests. Top-level blocks have depth 0, so
depth 1 also includes their immediate children. Width remains unbounded by the
depth restriction. A small visible refresh can therefore perform substantial
unnecessary work.

Page-tree scope revisions are not merely unused response fields. The App can
retain one as a deletion precondition when a parent's Children revision is not
available. Removing the capability requires coordinated contract and deletion
changes, not just removal of the digest calculation.

Relevant production owners and consumers:

- `logseq_overlay_db/lib/database.ml`: logical snapshots, structure traversal,
  scope calculation, mutation admission, and deletion planning.
- `logseq_overlay_db/spec/{types,database}.mli`: public structure results and
  write preconditions.
- `logseq_db_worker/contract/protocol.{ml,mli}` and
  `logseq_db_worker/lib/effect_runner/effect_runner.ml`: wire contracts and
  conversion to/from public Database operations.
- `app/journal_graph_runtime.ml`: timeline reads, retained revisions, deletion
  preconditions, and refresh/reconciliation requests.

## Decision

### Fixed requirements

The user explicitly requested an exploring document combining the Page_tree
read optimization with removal of the page-tree revision capability. Removing
that capability is a requirement, not an open alternative in this exploration.

1. Remove the page-tree collection revision from public results, write
   preconditions, Worker protocol variants, codecs, and App bookkeeping.
2. Remove the second traversal and all page-tree scope digest generation.
3. Select a bounded response window before constructing complete block records
   and their per-block revisions.
4. Share hydration work across selected blocks and avoid ident enumeration per
   visited node.
5. Preserve coherent snapshots, overlay visibility, ordering, depth semantics,
   and retained cursor semantics.
6. Retain per-block revisions, page revisions, Children revisions, and
   projection/generation checks. This change does not remove every revision
   mechanism.
7. After validating the root block revision, delete the latest logical subtree
   visible at serialized local admission. The user confirmed this deletion
   semantic on 2026-09-07.

Implementation was requested on 2026-09-07. The user explicitly authorized
necessary spec edits. The coordinated implementation and verification are
complete; evidence is recorded below.

### Remove the complete page-tree revision surface

The target `Page_tree_result` and `V2_page_tree_outcome` carry `page`,
`maximum_depth`, `items`, and `next_cursor`. Individual tree items retain their
block revision, parent, and depth.

Remove:

- `Types.Page_tree_revision` from `structure_revision_scope`.
- `revision_scope` and `scope_revision` from page-tree results only.
- `V2_page_tree_scope` and `V2_page_tree_revision`, including parsers, encoders,
  conversions, examples, fixtures, and catalog entries.
- The page-tree branches of scope-key generation, scope equality, and current
  scope calculation.
- App retention and lookup of page-tree scope revisions, including the
  page-tree precondition branch in `delete_preconditions`.

Keep `Page_tree_interest` / `V2_page_tree_interest` change notifications and the
App's registered page-tree interests. These identify views to refresh and do
not depend on a collection digest. Do not remove the generic request `revision`
field from other APIs as a side effect of removing page-tree scope tokens.

There is no compatibility layer, placeholder revision, constant digest, or
replacement page-wide token. Obsolete page-tree scope inputs are rejected by
the updated contract rather than silently accepted or translated.

### Read structure on demand, hydrate the selected window

Replace `walk all complete records -> paginate -> recompute scope` with:

```text
Enumerate ordered logical child facts on the visited frontier
    -> Traverse in the existing depth-first order
    -> Skip the cursor offset
    -> Select up to limit valid nodes and one valid lookahead
    -> Hydrate only selected nodes with shared caches
    -> Return items and an optional continuation
```

The structural reader resolves the minimal fields necessary for identity,
logical parentage, order, depth, and eligibility. It must merge authoritative
facts with active local insertions and deletions and preserve the current
visibility rules for malformed or missing entities. Reuse appropriate existing
logical child-fact helpers after examining their materialization behavior; do
not route the new selection loop through `child_items` if that still builds
complete records for all siblings.

Preserve the current order comparator and tie behavior. Preserve UUID
deduplication, local nested insert visibility, tombstones, valid parent/page
references, and depth boundaries. A node that would not produce a visible
logical block today must not consume a response slot merely because it has a
`block/parent` fact. Candidate validity must be established before deciding the
lookahead and `next_cursor`.

Selection must not load titles for display, full property summaries, task
status, rendered page metadata, or block revision digests for every skipped or
lookahead node. Minimal title or other field checks required to establish
existing record validity remain legitimate selection work. Selected records
use the same logical content and per-block revision semantics as public point
reads, including pending overlay effects.

The parent AVET index orders by parent/entity rather than by sibling display
order. Obtaining the first child may therefore require reading and ordering
the lightweight facts of a wide sibling group. Removing the collection digest
does not make every first request strictly O(limit). The concrete access goals
are to avoid traversing unneeded descendant branches, avoid unrelated graph
scans, and make complete record construction proportional to returned items.

### Keep cursor semantics; avoid a new mandatory whole-tree cache

Retain the existing projection-bound numeric structure cursor, offset ceiling,
limit range, invalid/stale error behavior, and currently documented reuse of an
offset with another request shape. Pagination remains coherent with the roots
captured by its snapshot. A keyset or traversal-stack cursor would be a separate
contract decision and is not required here.

With offsets, a continuation can still need to revisit preceding lightweight
structure. This is an explicit remaining cost, not justification for hydrating
preceding blocks. With the page-tree digest removed, there is no requirement to
enumerate an entire depth-bounded tree or cache a complete tree before serving
the first window.

Use operation-local caches for selected-block property definitions, reference
UUIDs, logical page titles, and already-read candidate fields. Cache actual
logical page titles against the captured overlay/root state; authoritative
titles alone can be stale under local effects.

Cross-request reuse is a measured follow-up within the same design if repeated
frontier work warrants it. Worker creates and releases a snapshot for each
request, so a cache on an individual snapshot lease cannot provide pagination
reuse. Any shared cache must be bounded by entries/bytes, owned by Database,
keyed by the captured authoritative and overlay roots plus request scope, and
safe for old snapshots and concurrent reads. Eviction must release retained
roots. A hidden full-tree warm-up or unlimited history retention is not an
acceptable substitute for bounded selection.

### Deletion after removal of the page-tree precondition

Confirmed semantics (Q1, answered on 2026-09-07): a delete targets the latest
logical subtree visible at serialized local admission. Validate the target root's block
revision, then enumerate the current subtree and freeze the existing delete
artifacts/footprint within the same serialized operation before durable
publication.

Under the confirmed contract:

- `Delete_blocks` requires the root block precondition, not a page-tree scope
  or a newly fetched parent Children scope.
- App deletion no longer requires any retained structure token. A changed root
  revision still produces the existing conflict behavior.
- A child already present in the local logical view when the delete is admitted
  is included, even if it appeared after the user's earlier timeline read.
- The frozen delete footprint is not expanded later without the existing
  conflict/replanning rules. Remote changes that arrive after local admission
  remain subject to existing queued/submitted delete conflict, receipt, and
  authoritative reconciliation behavior.
- Parent Children revisions remain available and required where currently used
  for insertion. Save and task-status mutations retain their block checks.

This is a deliberate change in the local deletion precondition contract. The
existing parent Children or depth-1 page-tree precondition does not provide a
complete arbitrary-depth subtree read-set guarantee, so retaining one is not a
substitute for deciding deletion semantics explicitly.

Deletion is not restricted to the subtree observed during the user's earlier
read. No observed-subtree target set or read-time page-tree digest is introduced.

### Implementation boundaries and sequence

1. Record the production ownership boundary for each regression, including the
   confirmed latest-local-subtree deletion contract.
2. Specify the reduced Page_tree result/scope contracts and the chosen delete
   preconditions. Identify all consumers with exhaustive searches.
3. Remove page-tree digest computation and its complete protocol/App surface in
   one coordinated change; preserve Children and item revisions.
4. Introduce lightweight ordered traversal, bounded selection, and selected-only
   hydration. Reuse selection facts instead of reading the same entity again.
5. Update deletion admission/App construction and relevant narrow correctness
   regressions, then run public-API access-count and latency measurements.

The simple earlier suggestion to derive a page-tree digest from the first full
walk is superseded: the final design contains no page-tree digest. Likewise,
retaining full hydration before pagination is not a complete fix.

Public changes will require coordinated edits to
`logseq_overlay_db/spec/types.mli`, potentially its `database.mli` documentation,
and the Worker contract. The user authorized implementation and necessary spec-interface edits on
2026-09-07. Do not modify OCaml implementation
files under `spec/`, any Dune file, or OCaml in bonsai_flutter. If the approved
spec is unclear or insufficient, report the specific issue before development.

No navigation or new confirmation UI is proposed. The App must continue opening
the most recently opened graph immediately on launch, as required by
`docs/ux-guidelines.md`.

## Alternatives considered

### Reuse the first traversal to compute the page-tree digest

This would remove duplicate reads but retain the collection capability that the
user explicitly wants removed. It also leaves complete pre-pagination hydration
unless selection is redesigned separately.

### Delete the digest and leave the first full walk unchanged

This removes one traversal, but limit 1 still constructs every complete block
in the depth range. It fails the bounded-content requirement.

### Replace the digest with a page-tree revision counter

This adds incremental counter ownership and invalidation while preserving a
page-tree revision capability. It does not meet the requested removal.

### Require a parent Children read before every deletion

This can preserve a narrow parent-membership guard but adds a read and still
does not verify an arbitrary-depth subtree. The user selected latest-local-
subtree deletion with a root block revision check in Q1; this additional parent
read is not part of the confirmed deletion contract.

### Remove all revisions

Block/page optimistic checks, insertion's Children checks, and projection-bound
cursor validation have separate consumers and semantics. They are outside the
requested removal.

### Build a complete cached tree for every projection

This can speed later pages but preserves full first-read work, adds memory and
invalidation costs, and is unnecessary once the collection digest is gone.
Bounded, root-keyed reuse of visited frontiers can be considered after measuring
the new traversal, without making full materialization a prerequisite.

## Acceptance criteria

- All page-tree collection revision fields, scope variants, codecs, App cache
  entries, and write-precondition consumers are removed. No placeholder or
  compatibility path remains. Children revisions and tree-item block revisions
  remain available. Page-tree refresh interests continue to work.
- Page_tree preserves visible items, logical content, depth-first order, tie
  handling, maximum depth, and per-block revisions under the same snapshot.
  Results exclude exactly the same invalid, missing, and tombstoned candidates.
- Limits 1 and 200 cause complete block hydration/revision work for their
  returned windows only. Skipped nodes and the valid lookahead do not receive
  full hydration. Minimal validity reads and necessary sibling ordering are
  counted separately and reported honestly.
- A prefix request does not visit descendant branches beyond those needed for
  selection/lookahead. Increasing unrelated graph contents or descendants in
  unvisited branches does not increase its graph datom consumption.
- No page-tree scope computation causes another traversal. Ident/property
  metadata work is shared or resolved on demand and does not grow one full
  ident scan per visited node.
- Continuations contain no missing or duplicate valid nodes. Existing cursor
  offset, limit, shape-reuse, malformed-cursor and stale-projection behavior is
  preserved. Old snapshots remain internally coherent after local or remote
  changes.
- The confirmed deletion behavior is verified: a changed root revision rejects
  the delete; descendants already present at local admission are included even
  if absent from the earlier read; later remote changes retain existing conflict
  handling against the frozen footprint. Cover local inserted children,
  queued/submitted deletes, and conflict-driven refresh.
  Insertion, save and task-status checks continue to operate as specified.
- Regression work first identifies the production state owner and attempts
  reproduction through its public pure reducer events, completions, state and
  effects. If that boundary reproduces the defect, add only its pure reducer
  regression. Otherwise document the missing ownership boundary and test only
  the narrowest public layer that executes it. Do not duplicate database
  regressions across runner, transport, integration, E2E and UI layers, bypass
  `.mli` boundaries, or remove existing tests to reclassify coverage.
- Public `Database.get_structure` probes record consumed datoms, complete block
  hydrations, ident loads, query calls, SQLite node restores, allocations, and
  elapsed time. Test narrow/deep and wide trees, rich properties, interleaved
  entity IDs, order ties, multiple offsets, nested local insertions and deletes,
  and malformed candidates. Include the prior offline mirror for comparison;
  do not send mutations to the remote user graph.
- Establish before/after baselines on the implementation checkout: historical
  counters above are evidence of the original issue, not fixed performance
  gates for a changing checkout. Separate warm/cold cache samples, API datom
  counts from physical node reads, and instrumented from release timings.
- Run relevant overlay read/mutation tests, protocol validation, App request
  mapping tests, the relevant release benchmark, and `spec-dev-tool check --all`.
  Use existing build/test declarations; this scope does not authorize Dune edits.

## Consequences

- Latest-local-subtree deletion can include descendants the user did not see.
  The user explicitly accepted this consequence in Q1 on 2026-09-07; it remains
  a behavior to verify, not an unresolved decision.
- Wire/spec removal is intentionally breaking and requires coordinated producer
  and consumer updates. Leaving an App scope lookup behind would strand delete
  actions even if reads themselves became faster.
- Lightweight eligibility checks can change which nodes occupy offsets if they
  differ from existing logical-record visibility, especially for malformed data
  or active overlay insertions/deletions.
- Sibling ordering can remain O(C) in a wide visited parent, and offset
  continuations can revisit O(offset) lightweight nodes. Neither should be
  misreported as O(limit) total database work.
- A cache keyed only by page UUID, projection number, or authoritative state can
  return stale overlay content or cross snapshot generations. Unbounded shared
  caches can also retain old database roots indefinitely.
- Removing the second traversal alone does not bound allocations in the first
  traversal. Shared page/property helpers also serve other APIs, so any changes
  to them need focused semantic verification.

## Questions

- **Q1 — Deletion semantics — Answered on 2026-09-07:** The user confirmed
  deletion of the latest logical subtree present at serialized local admission,
  after validating the root block revision. Include descendants that became
  locally visible after the earlier read. Freeze the footprint at admission and
  retain existing later sync-conflict handling. Remove page-tree collection
  revisions as already required.

No open questions remain. Necessary spec-interface changes were explicitly
authorized on 2026-09-07.

## Execution and regression ownership

- [x] Write the complete regression set, including pathological selection cases.
- [x] Verify behavioral RED failures before implementation.
- [x] Implement bounded reads, reduced contracts, and deletion admission.
- [x] Verify GREEN, simplify the implementation, and rerun relevant checks.
- [x] Record instrumented and release before/after evidence and finish validation.

The public Worker reducer was replayed through graph opening and both Page_tree
and Delete_blocks Graph_request events. It emitted the unchanged Execute_request effect. It exposes no
Database roots, tree traversal, hydration, or mutation admission state. Injecting
an expensive read result or an admission failure as a runner completion would
not reproduce these defects. Database is the narrowest public executable owner
for selection, snapshot consistency, and latest-local-subtree admission.
Existing sync conflict regressions retain their existing ownership and coverage.
App request construction and protocol decoding have separate owners and are
verified only for their changed contracts, not by duplicating Database regressions.


## Implementation evidence

The complete verification report, baseline source identity, RED traces, raw
instrumented and release measurements, and benchmark gates are retained in
[the page-tree read report](../../../test-reports/2026-09-07-page-tree-bounded-reads/README.md).

On the retained offline mirror, depth-64 limit-1 consumption fell from 126,532
to 475 datom results; full logical block calls fell from 538 to one. Limit 200
consumes 3,736 datom results and constructs exactly 200 logical blocks and item
revisions. No page-tree ident enumeration remains. Wide sibling ordering and
numeric-offset traversal remain explicit lightweight costs.

The final build, complete repository tests, protocol/App checks, changed-source
formatting, Python/JSON validation, and the existing 100,000-block release
benchmark gates all passed. Necessary `.mli` edits were limited to the overlay
result/scope contract and its deletion/read documentation. No Dune files,
OCaml implementations under `spec/`, or bonsai_flutter OCaml were modified.
