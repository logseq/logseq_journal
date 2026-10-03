# Journal UI Update Boundaries

## Problem

Journal has measured update amplification in two independent owners. Native
Swift List lifecycle callbacks repeatedly decode the complete list payload and
rebuild positions. The OCaml application observes the whole model and rebuilds
retained row candidates for changes that produce only one property patch or no
patch. Stable node reconciliation limits some downstream changes, but does not
recover the time already spent constructing and comparing those candidates.

This decision records where display snapshots, row identity, local state and
update work should be owned. It does not assume that every SwiftUI body
evaluation causes layout or painting. The intended outcome is the same UI and
domain behavior with work proportional to the relevant change.

### Verified baseline and evidence limits

An isolated fetch of Journal main on 2026-10-03 still resolves to
`c33fbe26a9e2cef570512c468cf95c3c91b2b233`. The audited LUI main and Journal CI
resolved dependency is `f00846f0aa0607638249a17e0522d2ed88e09159`. The implementation fetch confirmed Journal main unchanged and LUI main advanced
to `4b06cac01f7c7b323caa4050786a799eab58ea2d` (29 public extension-context API
lines, no OCaml/cache changes). Native matched fixtures use the same current LUI
4b06 on both sides; do not compare different dependency implementations.

| Baseline | Observed result | Boundary and limitations |
| --- | --- | --- |
| 500 text rows, 24 forward programmatic scroll requests | 667 row lifecycle events, 1334 full payload decodes; decode sum 6560.87 ms Debug / 6050.68 ms Release | Actual production Swift List and LUI backend in an isolated Simulator host; no live OCaml bridge, database, network or worker |
| Same Release traversal | DisplayLink callback gap mean 132.11 ms, p95 646.52 ms, max 696.25 ms | Callback gaps, not rendered FPS or hardware gesture measurements |
| Fixed 200 position lookups at 500 rows | Mean decode 4.943 ms Debug / 4.607 ms Release | Fixed query count separates per-query cost from scroll distance |
| Release small controls | 25 text rows: callback gap mean 17.20 ms; 100 mixed image rows: 17.51 ms | One run per case, shared host; does not characterize all real images |
| Production OCaml component probe, 500 retained rows, local input proxy | 1 root / 500 row builds, 1 patch, 27.41 ms | Public Timeline/media/Lui_app interfaces, synthetic data and a proxy input label; not the complete composer event chain |
| Same probe, changed visible range | 1 root / 500 row builds, 0 patches, 27.85 ms | Actual action already suppresses repeated identical ranges; the probe intentionally publishes a new model |
| Same probe, Journals-to-Detail media scope parameter | 9014 ops; create/drop each 1502; 50.28 ms | Empty media wrappers, component identity proof; not complete navigation latency or image decode count |
| Native list build alone, three iterations averaged | 1000 / 2000 / 4000 rows: 1.62 / 6.43 / 27.17 ms | Desktop OCaml timing corroborates repeated append/length complexity |
| Synthetic append-25, actual Release backend.apply(json:) | Initial 500 text rows: 474240 bytes, 111.06 ms | Real backend apply, precomputed production-renderer patch; not real database pagination |

The OCaml probe reuses existing builds after verifying all 58 relevant `.ml`
inputs against the audited sources. Its local signal build differs from the CI
signal revision; timings are directional samples, not release acceptance
thresholds. Position timings include their decode; never add those totals.
Detached image decode time is not main-thread blocking time. Simulator and
desktop measurements cannot substitute for iPhone frame capture.

The complete audit contains 14 findings and the actual-operation coverage matrix:
[UI rerender audit](https://chatgpt.com/api/library/files/libfile_92692f337ea08191b07512a6d51fbadf/download),
[supporting evidence](https://chatgpt.com/api/library/files/libfile_242e19dd191c8191a73bcb3c8c81c120/download).
These are private Library artifacts already saved with user permission;
repository readers without access can use the fixed source references below.
The original local evidence is
`/Users/rcmerci/Documents/Codex/2026-10-03/task-2/audit/`.
Runtime logs, generated reports, fixtures and screenshots remain outside Git.

## Decision

Use the following update boundaries as the recorded design direction:

1. One immutable, prepared native List snapshot per payload change, with cached
   decoded properties and row positions.
2. Application selectors for independently changing destinations, composer and
   chrome, followed by keyed row projections where evidence justifies them.
3. No-op identity preservation in production state owners, stable retained
   Timeline media identity and no eager construction of unused pages.
4. Linear native child construction and stable-order LUI child reconciliation.
5. Separate measurement of wire encoding, parsing, validation and commit before
   moving parsing off the main actor.

### Recorded user decisions — 2026-10-03

The user answered all four questions: "全部按建议，4. 在ios模拟器上测试".
The selected initial scope is stages 1–3, preserving retained rows and the
existing wire. Stage4 LUI work remains a separate review. Prefer a Journal-local
snapshot/cache; propose a minimal LUI revision/snapshot accessor only if the
current public boundary is demonstrably insufficient. Defer retained-row
eviction and incremental list wire until residual memory/payload evidence
justifies separate decisions.

Use iOS Simulator Release for testing, with three matched rounds. Calibrate the
baseline before setting final timing thresholds; structural/count gates can be
evaluated independently. Simulator results are not hardware iPhone FPS or
hardware timing results. The user subsequently authorized implementation with
"实现". Implement only stages1–3 and their correctness/three-round Release
Simulator verification; Stage4 remains separate, and no remote submission or
upload is authorized.

The primary decision is ownership and propagation of UI updates. Generic LUI
algorithm work supports that boundary, but its implementation must be reviewed
in LUI and coordinated with the Journal dependency SHA. It is not implicitly
authorized by creating this document. Stages1–3 were authorized and this
document transitioned to `proposed` before source edits. The implementation
record below distinguishes completed work from separately reviewed stages.

### Non-goals and invariants

- Preserve the existing C/native host layout and bridge ABI, native List,
  Section, ForEach, Toolbar, intrinsic sizing, navigation and fixed media slot
  dimensions. Do not recreate scrolling with per-row geometry tracking or
  scroll compensation.
- Preserve synchronized graph generations, draft/editor sessions, stale
  completion rejection, capture task intent, save errors, pagination anchors,
  deletion recovery and the current available undo semantics. Do not broaden
  into a new Undo/Redo capability.
- Do not add whole-graph reads to obtain row versions or compute selectors.
  Existing interest hydration, bounded requests and reference-source equality
  remain useful owners.
- Do not change visual styling, cache memory limits, write permissions or
  modal interaction semantics merely to reduce patch counts.
- Do not conflate the separate status/delete `row_event` dispatch defect or
  root Retry defect with the rerender cause. Track them separately; status
  transition tests require a working event boundary. This exploration neither
  diagnoses nor fixes root Retry.
- Limit production/test changes to stages1–3. No Dune edits, protected `spec/`
  OCaml changes, remote commits, PRs or uploads are authorized by this task.

## Update ownership and invalidation model

Use separate counters for reducer/effects, selector/tree construction,
mount/diff/patch, wire encode/decode/validate/commit, SwiftUI body, layout/frame
callbacks, actual drawing and image decode. A zero-patch update can still be
expensive in OCaml. A body evaluation may reuse all child rendering. A frame
dictionary update is not itself a root invalidation.

Let N be retained row/content count, D retained days, M retained LUI nodes, V
visible child views, K changed row dependencies, and G graph size. Optimize
N/M-dependent work without replacing it with O(G) reads. Some native List
payload operations will remain O(N) until a separate incremental wire decision
is justified. Do not promise all updates are O(1).

### Swift decoded payload and positions

The current `JournalList.View.properties` decodes `context.property("payload")`
on every read. `positions` decodes and walks sections; a lifecycle callback then
calls `updateVisibleRange`, which decodes again. Body/style/scroll targeting
also read the same property. The debounce only limits emitted range events.

Prefer one extension-instance-owned prepared snapshot containing decoded
Properties, payload lease/revision, flattened visible row keys, key-to-position
index, track flags and scroll metadata. Position flattening must match the
existing disclosure ordering; section headers/footers are child content indices,
not row visibility positions. Keep the snapshot separate from row child content
models so text/image property updates do not force payload parsing.

| Option | Cost and scope | Reason for current preference |
| --- | --- | --- |
| Parse a snapshot at payload-change boundary; callbacks capture/read the snapshot | O(bytes + N) on changed payload; expected O(1) key lookup per callback | Preferred ownership; no decode or full JSON comparison during scrolling |
| View-local memo keyed by an exposed immutable extension revision | Constant revision check; may reconsider child-only revisions, but parse only changed payload | Small candidate if current context cannot supply a payload-change snapshot; an additive LUI accessor needs its own review |
| Dictionary cache keyed by the entire payload string on every getter | May retain multiple full payloads and repeatedly hash/compare O(bytes) | Insufficient as the final hot-path design; replacing decode with a whole-string lookup is still amplification |
| Global cache keyed only by node ID or graph name | Cheap lookup but stale/reused node risk and unbounded lifetime | Not preferred; ownership must include extension instance/generation and disposal |

The available context API does not currently expose a public payload version.
The selected first approach is a Journal-local snapshot/cache at the existing
extension update boundary. Demonstrate that boundary before adding the cache;
only if it is insufficient, propose and separately review a minimal LUI
revision/snapshot accessor. Do not reach into private backend state or invent
an inaccessible API in a regression test. A display
revision is an invalidation hint, not permission to deliver an obsolete action.

Store visible **keys**, then derive positions from the current snapshot. An
index-only Set becomes wrong after insertion/reordering. A changed snapshot
intersects visible keys with current rows and remaps them once; callbacks must
not leave old indices in the Set. Do not scan N rows in each callback. Snapshot
preparation may prune keys once per payload change; range endpoint bookkeeping
should use V, not N. The existing visible Set sort is O(V log V); measure before
adding another ordered structure.

| Invalidator | Required rule |
| --- | --- |
| Identical payload / duplicate appear or disappear | Reuse prepared properties/positions; unchanged Set produces no new debounce task or delivery |
| Append pagination, insert/delete/restore, reordering, changed day grouping | Rebuild index once; preserve surviving visible keys and recompute current range |
| Disclosure expansion/collapse | Reflatten visible descendants; prune hidden descendants; late old child callbacks cannot reintroduce them |
| Edit/status/menu changes encoded in payload | Decode the new payload; reuse positions only after structural equality/version proves order unchanged; do not rely solely on a row-count match |
| Row child text/tag/media property change without payload change | Child revision changes locally; keep decoded list/index snapshot |
| Scroll token/target/track flag/style change | Refresh affected snapshot fields even if row keys unchanged; preserve token completion/supersession semantics |
| Graph/runtime/extension replacement | New lease; clear visible/delivered/pending/task state; reject scheduled work belonging to old lease |
| Malformed payload, duplicate keys or missing child index | Preserve current validation/error semantics; no stale last-valid content from another lease; define explicit invalid snapshot behavior |

Callbacks currently dispatch asynchronously. Carry an extension lease and row
key, resolve the current snapshot on delivery, and distinguish old-lease work
from a same-lease payload update. Debounced ranges must be computed/validated
against the current snapshot so old indices are never emitted into new OCaml
row mappings. Define whether old same-lease appear/disappear should be remapped
or ignored, and cover insertion/collapse races with deterministic tests.

### OCaml selectors, rows and no-op models

The whole-model `dyn ~equal:(==)` is the outer amplifier. Prefer selectors for
manager/authentication, root chrome, destination, direct capture, Detail draft,
Timeline presentation and Favorites presentation. Comparisons must describe all
display dependencies and retain structural sharing; they must not deeply compare
the entire model at every keystroke.

Separate control state (visible demand, pagination/request bookkeeping, upload
leases) from row presentation. A range event still updates demand/effects, but
should not invalidate row content when its display projection is unchanged.
Do not remove required requests merely because a UI snapshot compares equal.

For Timeline rows, consider a stable keyed child with a row presentation signal
covering block revision, referenced source/title versions, task/tags, media view,
interaction gate and required layout environment. Update the signal for K dirty
roots from already-owned changes. A newly allocated map with equal entries must
not imply all row signals changed. Avoid N subscriptions each scanning N rows or
each querying the database. An O(N) root projection per feed page is acceptable
initially if local keystrokes/visibility and one-row updates stop rebuilding N
rows; measure before building a complex selector engine.

Event handlers must continue reading current state, permissions and generation
at delivery. Do not capture stale block/status/session inside a cached view.
Local row expansion and media preview state_slot contexts retain their current
owner; selector scoping must not dispose them on unrelated updates. Handle row
removal and graph replacement explicitly.

Fix no-op identity first at its actual production owner: when a child reducer
returns the same capture/routes object and no other field/effect changed, retain
the outer state. `track_capture_session` can return its input when
`next_local_sequence` already satisfies the session invariant. Duplicate close,
same intent and stale scroll/edit completions need public reducer reproduction;
do not skip a necessary effect because the display remains unchanged. Timeline
already guards repeated identical ranges; retain that protection.

Media should publish only a changed final view. Repeated `root_visible true`
currently generates a fresh notification; compare visibility and the view before
publishing. Keep same-root callbacks coalesced in a flush. Dirty-root refresh
can use graph change relationships and existing leases, not a new whole-graph
lookup. Invalidation of media dependencies and Favorites membership is broader
than block text; exact refresh filtering needs separate correctness tests.

### Retained pages and media identity

The selected initial scope retains all currently loaded rows. Source review
during implementation confirmed that `Journal_view.Navigation_stack` is an
emulated router: it mounts only the top destination, so the current product
does not retain a native/LUI Timeline root behind Detail. Avoid eager unused
Timeline construction and verify the actual Back remount; a separate synthetic
SwiftUI NavigationStack cannot prove this product behavior. Preserve existing
anchors and row model state without introducing a new navigation architecture. Margin4
limits prefetch demand, not row retention; media64 groups and image32 items are
different limits. Stabilizing update work must not pretend N is bounded.

Move eager `Journal_timeline.view` construction inside the used Journals branch
when Favorites is selected. Use independently subscribed presentation subtrees when mounted. Detail draft
changes must not build an unused Timeline candidate. The existing top-only
router remounts Timeline on Back; actual Simulator integration must check its
current behavior and draft retention, rather than asserting retained root IDs.
Decide whether off-screen Timeline demand can pause independently of content
retention; do not silently change worker interests in the first phase.

Use media identity rooted in its owning presentation: Timeline scope based on
graph generation and stable Timeline destination, Detail scope based on graph
generation and its detail session. A temporary current route/detail request
counter must not change every retained Timeline media key. Retain graph isolation,
stale completion checks, media leases and preview teardown on actual owner
replacement. Empty wrappers need stable identity as much as image rows do.

| Retention option | Trade-off | Current position |
| --- | --- | --- |
| Keep N retained rows, local subscriptions and cached native snapshots | Memory remains O(N); removes repeated O(N)/O(N²) work from common local events | Preferred initial scope |
| Bound data/LUI retention and refetch on back-scroll | Can bound N/M but risks anchor restoration, expanded state, deletion recovery and new DB work | Separate future product/architecture decision, not a prerequisite |
| Native viewport virtualization only | Swift List limits native cell work, but OCaml rows, payload and LUI nodes still retain N | Necessary existing behavior; not a solution for model/tree costs |

Image decode remains a separate local owner. Investigate per-key in-flight
deduplication and cancellation before cache expansion. A 1024-pixel maximum
versus small display slots may warrant a DPR-aware thumbnail variant, but quality,
orientation and cache-key semantics have not been measured. Do not treat the
inactive `JournalMedia.View` cache-clearing path as the active Timeline loader.

### Native construction and LUI reconciliation

`Native_list.build.push` appends a singleton and calculates list length for each
child. Build with Rrbvec plus a monotonic content index, consistent with the
repository's sequence policy; convert only once at the existing list interface.
Preserve the exact header/row/footer/disclosure child order and indices. A
counter with reverse cons/rev is another linear option, but use the existing
Rrbvec dependency where appropriate rather than introducing a new sequence
library. Rrbvec removes repeated prefix scans; persistent tail copies and tree
paths still have their own costs, so near-linear samples alone are not proof of
strict O(N) construction. The full payload traversal remains O(N); later reuse
can avoid unchanged encoding.

LUI `emit_child_diff` repeatedly calls `List.length`/`List.nth` even for stable
wide parents. Cache length and use an array/vector or single traversal. Add a
stable-order fast path that proves the keyed order unchanged. Do not simply
replace keyed matching or move handling: deletion, insertion, swaps, duplicate
keys, unkeyed children and rollback must retain wire semantics. Checkpoint/table
copies and whole candidate traversal remain a separate O(M) cost even after
the O(N²) child walk is removed.

Maintain day/root indices with one Timeline slot pass if F14 measurement shows
`normalize_days` O(DN) matters. Indices must update for pagination, deletion,
restoration and graph reset. Do not persist a second graph index merely to
replace a retained presentation scan. Generic reconciliation changes need LUI
tests; Journal selectors must still work correctly with the reviewed dependency
version and not rely on a globally installed older package.

### Patch parsing, validation and application

Keep the runtime/commit on its current owner initially. Instrument event queue,
model, build, diff, encoding, Swift parsing, validation and touched commit as
separate intervals. Reduce needless work before moving it to another executor.
MainActor ownership protects SwiftUI state; OCaml reentrancy/order and C bridge
callbacks are not made thread-safe by moving one function.

For a non-nil validation scope, consider looking up its IDs directly instead of
iterating all M nodes then filtering; nil scope still validates all. Preserve
validation coverage, parent/extension relationships and atomic rejection. For
extension child membership, a cached Set/index can reduce O(VN) checks without
allowing content outside the extension's authorized children. Dispose indices
with their owner.

Only if measured residual parse cost warrants it, use the existing nonisolated
decode capability before an ordered MainActor apply. Assign receive order and
generation, decode into immutable batches, and commit in order. Handle obsolete
generation, failed batch and runtime disposal without committing later batches
against an invalid predecessor. Bound pending bytes/queue depth; do not let
background decode create an unbounded memory backlog. Modal and action delivery
must see committed state, and bridge acknowledgement semantics need explicit
review before decoupling synchronous receipt.

An incremental section/row payload wire could reduce full-payload parsing for
small updates, but changes both OCaml and Swift protocol owners. It is not the
minimal first fix. Likewise a shared list interaction gate can avoid per-row
payload updates, but must preserve all swipe/context/navigation blocking and
model-side write checks. Neither is assumed implemented by this exploration.

## Stages and dependencies

| Stage | Smallest deliverable | Depends on / release gate |
| --- | --- | --- |
| 0: baseline | Reuse audit fixtures; add missing layer counters only outside Git; freeze source/dependency hashes | No duplicate Simulator sampling while another owner profiles; no user graph |
| 1: native hot path | Journal-local prepared payload/positions snapshot, visible-key remap, duplicate lifecycle guard | Demonstrate existing public boundary; only if insufficient, review a minimal LUI accessor; deterministic payload-race tests; independent of OCaml subscription work |
| 2: cheap propagation cuts | No-op owner guards, media view equality, remove eager unused Timeline construction, linear Native_list build | Public reducer/serializer boundaries; no lifecycle or draft semantic change |
| 3: stable destinations | Separate composer/chrome/Timeline/Detail selectors; stable Timeline media scope | Preserve latest-state event delivery and graph fencing; test hidden-root and preview state lifetimes |
| 4: keyed dirty rows and LUI cost | Row dependency projection, reviewed stable-order linear diff, scoped validation/child membership | Outside the selected initial stages1–3; separate LUI review after Stage3 measurements; coordinated LUI SHA; keyed/unkeyed/rollback parity |
| 5: residual costs | Measure day projection/dirty refresh/image in-flight/frame diagnostics; optional ordered off-main parsing | Evidence after1–4; separate API/acknowledgement decision if parsing changes ownership |
| Deferred retention/protocol work | Bounded retained rows or incremental list wire | New explicit decision; not necessary to claim1–4 outcomes |

Stage2 can run alongside Stage1, but reviewers should assess each change
independently. Do not combine a parser thread move, retention policy
change and selector rewrite into one unmeasurable patch. Each stage must state
its final source hashes, what was measured and what remains unverified.

## Evidence and fixed source references

Audit finding labels map to the design above: F01 native cache; F02/F06/F07
selectors/no-ops/media notifications; F05/F08/F09 identity/page/gates;
F03/F04/F14 linear construction/projection; F10/F11 patch ownership;
F12 image work; F13 optional frame diagnostics.

- [JournalList payload, positions and callbacks](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/swift/JournalList.swift#L81),
  [decode helper](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/swift/JournalExtensions.swift#L95).
- [Whole-model subscription](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/application.ml#L5718),
  [capture session owner](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/application.ml#L400),
  [retained row construction](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/journal_timeline.ml#L42).
- [Media scope](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/application.ml#L1622),
  [unused Timeline construction](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/application.ml#L2061),
  [media wrapper identity](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/journal_media_view.ml#L304).
- [Native child build](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/journal_view.ml#L1918),
  [LUI child diff](https://github.com/logseq/lui/blob/f00846f0aa0607638249a17e0522d2ed88e09159/src/lui_runtime.ml#L496),
  [checkpoint](https://github.com/logseq/lui/blob/f00846f0aa0607638249a17e0522d2ed88e09159/src/lui_runtime.ml#L139).
- [Media notifications](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/journal_media_runtime.ml#L125),
  [refresh](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/journal_media_runtime.ml#L406),
  [Timeline day projection](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/app/journal_timeline_state.ml#L238).
- [Synchronous host apply](https://github.com/logseq/logseq_journal/blob/c33fbe26a9e2cef570512c468cf95c3c91b2b233/swift/JournalRuntime.swift#L131),
  [backend decode/apply](https://github.com/logseq/lui/blob/f00846f0aa0607638249a17e0522d2ed88e09159/platform/apple/Sources/LUIAppleBackend/LUIAppleBackend.swift#L645),
  [scoped validation loop](https://github.com/logseq/lui/blob/f00846f0aa0607638249a17e0522d2ed88e09159/platform/apple/Sources/LUIAppleBackend/LUIWireProtocol.swift#L995),
  [child membership/context API](https://github.com/logseq/lui/blob/f00846f0aa0607638249a17e0522d2ed88e09159/platform/apple/Sources/LUIAppleBackend/LUIAppleExtension.swift#L267).
- [File image loader](https://github.com/logseq/lui/blob/f00846f0aa0607638249a17e0522d2ed88e09159/platform/apple/Sources/LUIAppleBackend/LUIFileImageLoader.swift#L22),
  [frame reporting](https://github.com/logseq/lui/blob/f00846f0aa0607638249a17e0522d2ed88e09159/platform/apple/Sources/LUIAppleBackend/LUIAppleBackend.swift#L454).
- Existing decisions: [retire estimated geometry](../../implemented/simplification/2026-09-17-retire-estimated-list-geometry.md),
  [native root controls](../../implemented/simplification/2026-09-17-retire-root-scroll-visibility.md),
  [iPhone performance coverage](../../proposed/testing/2026-09-18-current-iphone-performance-coverage.md),
  [UX rules](../../../ux-guidelines.md). The performance follow-up is historically
  paused; this document does not silently resume it.

## Alternatives considered

### Only cache Swift properties and stop

The smallest measured scrolling improvement and the first stage. It does not
address 500-row candidate builds for a keystroke or route identity replacement,
so it is insufficient as the complete decision. Its result can ship separately
after approval without waiting for the larger selector design.

### Replace physical equality with deep whole-model equality

Could suppress some equal-new-record updates, but compares unrelated state and
large collections on every publish, still rebuilds N rows on real local input,
and can obscure effects/handler dependencies. Prefer identity guards at state
owners plus small complete selectors, not one global structural comparison.

### Cache every row view forever or key solely by block UUID

Can reuse construction but risks stale reference sources, media, permissions,
sessions and handlers, and leaks local state across graph replacement. Prefer
owner-scoped keyed row projections with explicit dependencies and disposal.

### Evict rows immediately or build a custom viewport

Bounds some costs but changes scroll/back/anchor behavior and risks reinstating
retired geometry coordination. Retain native virtualization and current row
retention initially. Consider bounded data retention only as a separate decision
after measuring the residual memory curve.

### Increase image cache or move all runtime work off MainActor

Pure text already reproduces Swift stalls. More image memory cannot fix them.
Moving mutable OCaml/C/backend owners wholesale introduces ordering/reentrancy
risks. Prefer local work reduction, in-flight image deduplication and measured,
ordered immutable parsing if still needed.

### Introduce incremental list wire and global interaction gate immediately

Could reduce payload bytes and gate updates, but expands protocol and action
semantics before the simpler snapshot/selector fixes are measured. Defer until
remaining O(N) payload and gate costs justify a separately reviewed contract.

## Acceptance criteria

All timing numbers below remain **suggested future acceptance gates**, not final
thresholds or observed post-fix results. The selected test environment is iOS
Simulator Release, with three matched rounds to calibrate the baseline before
final timing gates are set. Freeze and report the Simulator model, iOS version,
host, source/dependency hashes and fixture for all three rounds. Structural/count
gates can be evaluated independently. Baselines above are prior samples, not a
claim of full application coverage. Implementation verification is tracked
separately below and in the outside-Git evidence; component measurements do
not substitute for the complete Application/C/Swift integration chain.

### Functional and propagation matrix

| Boundary / scenario | Required functional behavior | Suggested observable update gate |
| --- | --- | --- |
| Native unchanged payload, 667 lifecycle events at N=500 | Correct debounced range and scroll completion | 0 full-payload decodes and 0 full position rebuilds after snapshot preparation; cached index lookups only |
| Duplicate appear/disappear or identical emitted range | No lost membership or needed demand | No new native debounce for unchanged membership; existing OCaml range guard remains |
| Append25, delete/restore, reorder, disclosure expand/collapse | Keys/index mapping and anchor correct, late callbacks fenced | At most 1 decode/index preparation per distinct changed payload lease; old surviving node IDs unchanged |
| Text/status/tag edit | Changed labels/actions visible; status dispatch works independently | Payload content invalidates when needed; unchanged positions reused only if structural identity/order proves equal |
| Runtime/graph switch with pending callbacks | No cross-graph content/events; current selected graph restored normally | Old lease ignored, cache cleared, required new root build allowed |
| Composer text/intent/attachments/error/save | Existing sessions, staged files, validation and sync semantics | 0 Timeline/Favorites row builds for draft-only state changes after boundary split |
| Public same intent, repeat close, stale edit/scroll completion | Preserve sequence invariant and legitimate effects | Same owner model when nothing changes; 0 display-root builds/patches |
| One root tag/media/reference changes, N=25/100/500/1000 | All dependent rows update, unrelated rows retain state | Row builds proportional to K; for the one-root fixture K=1, not N; no new graph reads |
| Favorites change or Detail draft update | Correct current destination; back restores scroll/expansion | 0 hidden Journal row builds; root identity remains valid |
| Detail open/back/request generation change | Native navigation and preview lifecycle correct | 0 create/drop of retained Timeline media wrappers; real graph replacement still resets them |
| Modal/pending write gate | All prohibited swipe/context/navigation remain blocked | O(N) gate patches are allowed until a separately accepted shared gate; never bypass correctness for a count target |
| Sync unrelated root / media duplicate visibility | Necessary dependency/Favorites updates continue | No equal-view media publication; refresh requests depend on affected roots, not unconditionally all64 groups, once dependency rules are proven |
| Image repeated key, cache pressure, cancellation | Correct image/token/quality, bounded memory | One shared in-flight decode per identical key; no stale token state; existing cache budget preserved initially |
| Patch invalid property/parent/extension or failed decode | Atomic rejection, no partially committed future batch | Same validation coverage; ordered generation-safe commit, if asynchronous parsing is adopted |
| Launch/auth/lifecycle/environment/preview | Actual visible state and keyboard/safe-area behavior remain correct | No per-second timer root update; same environment/lifecycle sampling remains deduplicated; local preview remains local |

The current UI has no search/tag/status filter, date picker or existing-block
body editor. Do not invent acceptance flows for them. Cover actual direct
capture save and Detail append-child save, plus remote metadata updates.
The independent status event fix must land or be tested at the picker/public
reducer boundary before claiming real swipe-to-save coverage. Root Retry has
its own validation; do not hide a nonresponsive action behind a performance gate.

### Scaling and timing targets

- Native list construction and unchanged wide-parent child diff should be O(N),
  not O(N²). On repeated matched 1000/2000/4000 fixtures, propose a doubling
  ratio at most 2.5 for the isolated operation median, after warmup and with GC
  reported. The current build-alone 1.62/6.43/27.17 ms is the baseline. This gate
  is an empirical signal; review implementation complexity as well.
- Native lifecycle callback preparation should not increase with retained N
  when V is held fixed. Propose a Release callback p95 below 1 ms on the agreed
  Simulator control, excluding unavoidable payload replacement. There is no
  existing callback-total baseline; the measured 4.607 ms is a single decode,
  not the callback p95. Establish the exact counter before applying this budget.
- For the local input/range fixture, after selector isolation propose no more
  than 10% median timing growth from N=100 to N=1000 with identical draft/V and
  no graph reads. Existing input is 4.71/64.96 ms and range 4.68/66.82 ms; full
  composer measurements remain to be obtained.
- A changed full list payload can remain O(N) per preparation. Cache memory is
  O(N) for one live snapshot/index per owner, with obsolete snapshots/tasks
  released; do not retain a history keyed by every JSON value.
- For the same Release500 scroll control, suggest a p95 DisplayLink gap below
  50 ms and no callback gap above 100 ms in at least three runs without a
  competing build, subject to the selected three-round baseline calibration.
  This remains a Simulator diagnostic suggestion, not a rendered-frame or
  hardware-iPhone acceptance claim. Actual iPhone measurement is outside the
  selected test scope and is not a prerequisite for these Simulator gates.
- There is no justified numeric target yet for append25 parsing/validation/
  commit. Split the 111.06 ms baseline first. Report bytes, per-layer times,
  queue latency and retained M rather than choosing an arbitrary aggregate
  target or masking work with asynchronous dispatch.

### Test ownership and verification

Use public production owners before adding regressions, as required by
AGENTS.md. Reproduce capture/no-op/Timeline behavior via pure events, completions,
state and effects in existing `test/journal_timeline_state_test.ml`,
`test/journal_semantics_test.ml` or the applicable application reducer tests;
do not inject an already incorrect transport result or duplicate the same
defect across integration/E2E suites. Use `test/application_view_test.ml` for
subscription/identity behavior that cannot be expressed at the pure owner.

Use the existing native Swift test/harness boundary for prepared payload and
late callbacks, and existing LUI Apple backend tests for validation/commit.
Generic child diff needs LUI public-runtime tests for stable order, insertion,
deletion, moves, duplicate/unkeyed children and rollback. Avoid private `.mli`
bypasses and copied implementation logic. Keep tests limited to the layer that
executes the defect, plus distinct cross-owner contract tests where necessary.

Implementation validation should follow existing OCaml/native/LUI commands for
the files actually changed, then required repository checks. Any need to edit
Dune or protected `spec/` interfaces must be surfaced separately before doing
so. Run `spec-dev-tool check` and `check --all`, link validation and
`git diff --check` alongside affected OCaml/native regressions and the required
final synthetic Simulator integration. Keep preexisting documentation failures
separate from this decision.

Report source and dependency hashes, fixture counts, repeated-sample statistics,
cache state, device/OS/build mode, concurrent load and every unmeasured layer.
Keep diagnostics and generated assets outside Git. A stage is accepted only for
the measured boundary; no claim of finding or fixing all UI bugs.

## Risks

- Cached indices can silently send valid-looking stale positions after reorder,
  collapse or a graph transition. Lease/visible-key rules are correctness gates,
  not optional optimization details.
- Small selectors can omit indirect dependencies such as referenced titles,
  media readiness or environment. Stale permissions/handlers are worse than
  excess work; exercise dependency changes and latest-state delivery.
- Narrowing dyn scopes can change state_slot ownership and destroy expansion,
  preview or editor sessions. Preserve keys and owner disposal semantics.
- Stable Timeline scope must not let media from a prior graph/runtime leak into
  a new graph. Detail-local identity and graph fencing remain separate.
- Linear diff and scoped validation can change ordering or weaken rejection.
  Preserve keyed/unkeyed matching, atomic rollback and authorization checks.
- Off-main parsing introduces queue, cancellation and acknowledgement semantics;
  it is conditional, not part of the first hot-path fix.
- Retained memory still grows with N after work reduction. Bounded retention is
  intentionally undecided and needs its own UX/anchor/data-lifetime design.
- Single-run Simulator/desktop numbers, a local signal revision difference and
  incomplete real-device flows limit timing conclusions. Proposed budgets may
  need revision after the selected three matched iOS Simulator Release baseline
  rounds; those results cannot establish hardware iPhone FPS or timing.

## Consequences

- The native owner prepares one snapshot per distinct payload. Unchanged row
  lifecycle and position lookup events do not decode or rebuild that snapshot.
  Changed payloads remain O(N); visible range calculation is O(V).
- Public no-op owners preserve physical identity. Independent Application
  presentation regions avoid unrelated retained-row construction while keeping
  latest-state event delivery and existing domain ownership.
- Meaningful media/reference/row updates can still build O(N) candidates and
  generic LUI reconciliation/validation remains unchanged. Retained rows, native
  slots and media cache limits are not bounded by this optimization.
- The actual emulated navigation mounts only its top destination. Detail Back
  reconstructs Timeline and mounts a new native List; component media wrapper
  identity evidence does not establish retained Timeline identity or position.
- The isolated Release native component comparison removes unchanged-scroll
  payload decode, but N500 callback-gap targets remain unmet. This is evidence
  of less native owner work, not hardware FPS, drawing or full-app latency.
- The first complete iOS Capture chain exposed a nested subscription disposal
  regression missed by default-platform tests. Moving its overlay outside the
  root content subscription fixes this regression; the public iOS/row-lifecycle
  test and actual native-editor chain now pass.

## Questions

- Should the initial implementation scope be stages 1–3, preserving all retained
  rows and the existing wire, with stage4 LUI changes reviewed separately?
  Answer: Yes. The user accepted the recommendation. Select stages1–3, preserve
  retained rows and the existing wire, and review Stage4 LUI changes separately.
- If the native owner cannot prepare snapshots through its present public
  context, should a narrow LUI revision/snapshot accessor be proposed, or should
  the first change remain Journal-local?
  Answer: Prefer Journal-local snapshot/cache. Only if the current public
  boundary is proven insufficient, propose a minimal LUI revision/snapshot
  accessor. The implementation boundary still needs technical validation.
- Should bounded retained-row policy and incremental list wire remain explicitly
  deferred until residual memory/payload measurements justify separate decisions?
  Answer: Yes. Defer both until residual memory/payload measurements justify a
  separate decision; retain native navigation/scroll behavior initially.
- Which Release iPhone model and repeat count should define final timing gates,
  and should the suggested diagnostic budgets above be adopted after baseline
  calibration? Structural/count gates can be evaluated independently.
  Answer: The user selected iOS Simulator instead of a hardware iPhone. Use
  Release, repeat three matched rounds, calibrate the baseline before setting
  final timing thresholds, and evaluate structural/count gates independently.
  Simulator results cannot be equated with hardware iPhone FPS or timing.

All four user decisions are answered. The subsequent "实现" request authorized
local stages1–3 and verification. The document transitioned to `proposed` before
source changes; the implementation below uses a Journal-local snapshot owner.
Remote submission, upload, Stage4 generic LUI changes and deferred
retention/protocol work remain outside this implementation scope.

## Implementation record

Stages1–3 are implemented locally on `feat/journal-local-ui-updates`. Generic
LUI code and the repository dependency specification are unchanged. Journal
main remains c33fbe26; current LUI main4b06 is identical on the two native
comparison sides. Exact source, compiled artifact and review-commit hashes are
recorded outside Git in `implementation-evidence/` in the task workspace.

- Native prepared snapshots cache properties/positions, track surviving row
  incarnations and visible keys, debounce ranges and reject retired instances.
  Suspension preserves content while disposal and graph generation reset
  ownership. The actual old getter RED400 decodes becomes GREEN1;37 native
  assertions pass.
- No-op root/route/media guards preserve unchanged state and required effects.
  Native child accumulation uses Rrbvec with monotonic indices and one final
  conversion. The isolated1000/2000/4000/8000 construction medians change from
  1.643/6.382/25.848/137.571ms to0.230/0.517/2.614/4.284ms. The2000→4000
  after ratio5.06 does not meet the proposed≤2.5 empirical target; strict
  asymptotic scaling or GC attribution is not established by these samples.
- Independently subscribed root/Detail/Capture/modal/chrome regions avoid draft
  and demand-only row construction. Favorites does not build unused Timeline
  descriptors. Media presentation keys use graph/destination or Detail session
  separately from runtime lease scopes. iOS Capture lives outside the root
  content subscription to survive asynchronous metadata updates.
- Final `dune build @all`, `dune runtest`, changed-file formatting and
  `git diff --check` pass. Application view tests are23/23. The registered macOS
  bytecode runner cannot load `_caml_startup` from `dllapp_stubs.so`; compiling
  its unchanged test sources against Dune's public native dependencies passes
  both groups. Native Swift is built Release in the actual Simulator fixture.

Three matched native component Release rounds retain the same47 resource
files and actual production wire inputs. N500 unchanged forward payload decode
counts1310/1402/1270 become0/0/0; callback-gap p95 median660.37ms becomes92.71ms.
Backward p95 median614.18ms becomes53.46ms. Those values remain above the
proposed50ms target. The append timer covers synchronous backend.apply only;
it excludes later queued preparation, layout and drawing.

The separate final full chain runs actual Application.For_testing, a serial
synthetic Worker, production C bridge and production Swift owners on iOS26.1
arm64 Simulator Release. Its three N50 rounds all pass with identical counts:

| Phase | Actual builders | Patches/ops | Payload decodes |
| --- | --- | --- | --- |
| Native Capture input | Capture1; root/Timeline/rows0 | 1/2 | 0 |
| Duplicate input | All0 | 0/0 | 0 |
| Native Append input | Modal1; Detail/root/Timeline0 | 1/2 | 0 |
| Unchanged native scroll after Back | All0 | 0/0 | 0 |
| Capture open / collapse | Timeline rows150 /50 | 1/259 and1/195 | 3 /3 |
| Detail Back | Timeline3, rows150 | 2/1884 | 1 |
| Media failed / ready | Rows50 /100 | 1/1 and2/18 | 0 |
| Duplicate Queued / manager | All0 | 0/0 | 0 |

Actual onscreen UITextView input preserves Chinese draft through collapse,
Detail/Back and reopening. Native Append Send inserts one synthetic child and
scroll-completed token1 succeeds once. Media ready uses synthetic provider
completion through real Acquire_asset_file and one real PNG decode; it does
not test the Retry button. No real DB/auth/network provider or user graph is
used. Host-arm64 complete OCaml objects reuse source-verified static C
dependencies and are retagged for Simulator as the existing tooling does;
this is not a new dedicated OCaml cross compiler.

An additional source/compiled-input-verified c33 full-chain comparison proves
Capture opening's native offset reset is preexisting (1500.67→−47); current
range0–8 matches actual visible items, while the original emits stale ranges.
Detail Back unmounts/remounts its native List by the existing top-only router.
A separate request-budget-respecting paged N500 fixture remains supplemental
scaling evidence; its result is recorded separately from the frozen three N50
acceptance rounds.

Drawing/FPS, hardware input/hitches, real sync/database performance, every
preview/picker/attachment/error lifecycle and root Retry/status delivery are
not established by these measurements. Meaningful media/reference/gate updates
still rebuild retained candidates; Stage4/retention/incremental wire/off-main
parsing remain separate. `spec-dev-tool check` passes this decision, while
`check --all` reports the unchanged older bottom-lui-capsules document missing
Problem/Alternatives considered/Consequences. No Dune or protected spec changes,
phone installs, personal asset changes, uploads or remote writes were made.
