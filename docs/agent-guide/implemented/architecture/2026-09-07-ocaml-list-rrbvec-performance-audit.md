# rrbvec for Retained Ordered State

## Problem

Three owned sequences in the non-test OCaml code have an operation pattern that fits rrbvec: ordered append with intermediate reads, retained pagination, or persistent positional edits. Their current List representation repeatedly copies prefixes or walks from the head to an already-known position.

This decision adopts rrbvec for three retained ordered sequences. The user approved the implementation and explicitly authorized its Dune dependency changes. The scoped behavior, allocation, retained-memory, and native-build acceptance checks are complete; [the acceptance report](../../../test-reports/2026-09-07-rrbvec/README.md) distinguishes collection benefits from the remaining complete-operation costs.

The source review covered 181 first-party OCaml files (95 `.ml`, 86 `.mli`) at commit `b32baf08ef0503cc84ab5df613607b058efa9e59`. Scope included `app`, the five `logseq_*` packages, read-only `spec/` interfaces, and `tool/` sources. Test directories, test-report reproductions, generated artifacts and external repositories were excluded from the candidate inventory. That inventory was read-only. The completed implementation now updates the three owners, their consumers, dependency declarations, and acceptance tests.

## Decision

Use rrbvec for the three sequences below, updating their internal consumers together. Keep required external List boundaries limited to returned pages or one-time conversion. R1 and R2 have direct positional/append benefits; R3 specifically targets bucket-copy allocation and has a wider shared-reader impact. The implementation uses that representation throughout all three owners; bounded external List results remain at their required interfaces.

| ID | Owned collection | Relevant operations | Expected structural benefit |
| --- | --- | --- | --- |
| R1 | Worker `database_session.windows` | Append, pull a page, acknowledge a prefix | Avoid growing-prefix copies; share retained slices. |
| R2 | Timeline `t.slots`, including the state retained by staged deletion | Window selection, adjacent-slot access, retention trimming, local replacement | Efficient positional reads and structural sharing across edits. |
| R3 | Replan block/page effect buckets | Append chronologically, read the current ordered prefix | Avoid copying each existing bucket on append. Effect replay remains linear in bucket size. |

These are three owner-level changes. Timeline slicing, point replacement and range editing are parts of R2, not independent conversion projects. R3 includes only buckets that the replan read path actually consumes.

### Evaluated package and operation bounds

The evaluated package is `rrbvec.dev`, pinned to `RCmerci/rrbvec` commit `dd5ce904f91d53235b5136f7a771f3f074c3971d`. The installed opam pin and inspected local source checkout identify that commit. Sources: pinned [README](https://github.com/RCmerci/rrbvec/blob/dd5ce904f91d53235b5136f7a771f3f074c3971d/README.md), [public interface](https://github.com/RCmerci/rrbvec/blob/dd5ce904f91d53235b5136f7a771f3f074c3971d/lib/rrbvec.mli), and [implementation](https://github.com/RCmerci/rrbvec/blob/dd5ce904f91d53235b5136f7a771f3f074c3971d/lib/rrbvec.ml).

Let `L(n) = 1 + log32(max(1,n))`, n be retained length, k selected length, and m incoming length. The following are documented/inspected bounds, not owner-level measurements.

| Operation | List | rrbvec |
| --- | --- | --- |
| Count | O(n) | `length`: O(1) |
| Read index i | O(i+1) | `nth` / `nth_opt`: O(L(n)) |
| Append one value | O(n) | `push_back`: O(L(n)) worst case |
| Persistent change at a known index | O(i+1) prefix copying | `set`: O(L(n)) |
| Select [a,a+k) | O(a+k) with `drop`/`take` | `subvec`: O(L(n)); emitting k List elements adds O(k) |
| Concatenate existing sequences | O(length of left) | Binary `append` / `concat`: O(L(n+m)) |
| Append incoming List | O(n) prefix copying | `append_list`: O(m+L(n+m)), including incoming conversion |
| Convert all values | N/A | `of_list` / `to_list`: O(n) |
| Traverse, search by predicate or replay effects | O(n) | O(n) |

`subvec v start stop` uses a half-open end index and returns an option. The package has no UUID index or direct range-replacement function; range replacement can use slices and binary concatenation. Use traversal APIs for scans rather than repeated `nth` calls.

### R1. Worker change-window retention

**Owner and baseline source locations**

- `logseq_db_worker/lib/effect_runner/effect_runner.ml:337–344`: `database_session.windows`.
- `:459–504`: `publish_projection_change`, including append at `:477–488` and generation/resync resets.
- `:821–895`: `windows_after`, `pull_changes`, `acknowledge_changes`.

**Observed workload**

Each projection publication appends a window to the retained List. Consumers pull ordered pages and later acknowledge a prefix. The collection survives across these operations. No explicit window-count cap exists in this owner; acknowledgement and resync shorten or clear it.

With W publications and no acknowledgement, `session.windows @ [window]` performs O(W²) aggregate prefix copying. A pull scans for a cursor and also traverses retained values to compare lengths. These are actual consumers of the ordered collection, rather than an unused intermediate result.

**Proposed representation and benefit**

Store windows as `change_window Rrbvec.t`, append with `push_back`, and retain/select ranges with `subvec`. Materialize only the returned page as the List required by the protocol DTO.

- W appends: O(W L(W)) sequence work instead of O(W²).
- Once a cursor position is known, page slicing and emission: O(L(W)+k).
- Count: O(1); retaining an acknowledged suffix: O(L(W)) after locating its boundary. The existing List already returns the found tail in O(1) without copying, so suffix retention itself is not an improvement and may allocate more with rrbvec.
- A predicate-based cursor lookup remains O(W). This proposal does not assume a new cursor index or promise logarithmic complete pull/ack operations.

A functional queue is a valid alternative for append/ack. The additional need for non-destructive pagination and retained subranges makes rrbvec a suitable choice here; comparative owner-level measurement should still include a queue where practical.

**Consumer and semantic requirements**

Keep internal windows as vectors throughout publication, pull and acknowledgement. Protocol `V2_changes.windows` remains a List built once for the selected page; that is an external representation boundary, not a legacy compatibility path.

Preserve exact cursor equality, generation checks, predecessor/successor ordering, zero-limit behavior, `through`/`next`, unknown-cursor resync, and acknowledgement boundaries. If a later design adds ordinal-based lookup, validate the exact cursor token and retained generation/range rather than accepting arbitrary parseable integers.

**Risk: medium.** Response encoding and cursor search remain outside the append improvement. rrbvec does not impose a retention cap or solve an indefinitely stalled consumer.

### R2. Timeline retained slots and persistent edits

**Owner and baseline source locations**

- `app/journal_timeline_state.ml:58–85`: `t.slots` and `staged_delete.before`.
- `:188–210`, `:355–367`, `:1254–1274`: retention trimming, visible-request collection, current window and count.
- `:410–429`, `:688–718`, `:900–1020`, `:1033–1212`: slot/day/children replacement, expand/collapse, insertion, deletion and undo.
- `:593–631`: block/entry replacement.
- `app/journal_timeline.ml:609`: preceding-slot lookup for timestamp grouping.
- `app/application.ml:402–415`: `block_in_timeline`, another consumer of retained slots.
- `app/journal_timeline_state.mli:53,113`: List-valued window and retained-slot access contracts.

**Observed workload**

The timeline keeps an ordered sequence across scroll events and graph updates. It selects a bounded visible window, reads adjacent slots, trims old prefixes and changes local portions while older state may remain referenced by staged deletion.

The retained-state limit is 512 slots; the emitted window limit is 40 rows, with overscan 4. Changes can construct a larger intermediate sequence before trimming. These bounds make actual latency benefits workload-dependent; they do not remove the positional nature of the operations.

**Proposed representation and benefit**

Store `t.slots` as `slot Rrbvec.t`. Treat all consumers of that state as one change.

| Existing operation | Vector form | Benefit and remaining work |
| --- | --- | --- |
| `current_window`: drop offset, take up to 40 | `subvec`, then materialize only the selected rows | O(L(n)+k), instead of O(offset+k). |
| Preceding/old-anchor slot by known position | `nth_opt` | O(L(n)), instead of O(index+1). |
| Visible-request scan after a skipped prefix | Slice the demanded range, then traverse it | O(L(n)+v) for v examined rows, instead of walking the prefix as well. |
| Retained count and prefix trimming | `length`, `subvec`, preceding-slot lookup | O(1) count and O(L(n)) sequence trimming. Day-failure cleanup can still scan. |
| Replace a known contiguous range | Two retained slices plus concatenation with the replacement | O(L(n)+m) sequence construction for m incoming List values. Finding the range may remain O(n). |
| Replace q matching slots | Find all matches, then `set` | Avoid full List reconstruction; search remains O(n), with O(q L(n)) structural updates. |

Persistent vector roots share unchanged slot structure across edits. This is useful for staged deletion, but saving an untouched List root is already O(1); the benefit arises when subsequent edits would otherwise copy prefixes. Slot order and payload semantics must remain unchanged.

**Consumer and semantic requirements**

The benefit-bearing operations are positional window/neighbor access, append/splice construction and localized replacement. Geometry, predicate searches and undo reconciliation are required consumer adaptations; they are not independently claimed performance improvements.

`current_window` may continue producing a bounded List for Flutter. Full retained-slot consumers must avoid an unconditional whole-vector conversion:

- Replace the renderer's `retained_slots` then `List.nth_opt` with direct indexed owner access.
- Give `block_in_timeline` an owner query or vector traversal. Its ID search remains linear, but must not first allocate a complete List.
- Update the retained-slot accessor and all callers as needed; remove an obsolete accessor instead of preserving a compatibility path.

No UUID-to-position index is assumed. Updating a positional index after a splice may cost O(n), so it must not be used to claim logarithmic total updates without counting its maintenance. Preserve all matching occurrences handled by the existing replacement maps.

`extent_geometry` still traverses retained slots and performs heading/membership work. Orphan-heading cleanup and undo reconciliation may also scan or merge multiple regions. rrbvec improves positional sequence operations; it does not establish a faster complete frame or logarithmic complete undo. Undo must preserve intervening updates rather than simply restoring `staged_delete.before`.

**Risk: medium/high.** Verify retained indices, heading boundaries, timestamp grouping, stable keys, visible anchors, expansion ownership, loading/cursor markers, concurrent updates and focus restoration. Keep the existing Flutter component and window limits.

### R3. Replan block/page effect buckets

**Owner and baseline source locations**

- `logseq_overlay_db/lib/database.ml:6474–6500`: `replan_queued_ordinary`, `add_indexed_record`, block/page bucket additions; append at `:6486`.
- `:6551–6552`: intermediate snapshot references to block/page effect maps.
- `:1985–2104`, `:2107–2355`: `logical_page_at` and `logical_block_at`, which search and replay the ordered bucket contents.
- `:6375–6394`, `:6435–6462`: mutation satisfaction/dependency checks that invoke those readers during replan.
- `:1613–1685`: bulk index construction and frozen queryable state, which share reader representation requirements.
- `:2372–2389`, `:2856–2919`: `block_is_tombstoned` and `logical_tree_candidate`, additional shared block-bucket consumers used by structure reads.
- `:1688–1723`, `:1759–1778`: snapshot construction and captured read roots that carry the same bucket representation.

**Observed workload**

Replan processes records in sequence order. Each active record is appended to its block/page UUID buckets, and subsequent records read the intermediate buckets in chronological order. These sequences are incrementally consumed; they are not one-shot results that can simply be reversed at the end.

For final bucket sizes d(u), current appends copy O(sum d(u)²) List cells. The outer UUID Map is already present and should remain a Map.

**Proposed representation and benefit**

Use vector values for the consumed block/page effect buckets. Append with `push_back` and let point readers use vector traversal directly. If S is total bucket memberships and U the number of keys, bucket construction becomes O(sum d(u)L(d(u))) sequence work plus O(S log U) Map work.

This is specifically a reduction in sequence construction/allocation. For repeated changes to one UUID, replaying bucket prefixes of lengths 1 through d still performs O(d²) element visits. rrbvec does not make complete replan subquadratic. Measure copied structure, GC and total replan time separately.

**Scope boundary**

Only the block/page buckets have demonstrated consumers on this replan path. The temporary `snapshot.outbox = Some (List.rev accumulated)` is not read by these calls; the full outbox read is in `local_journal_candidates` at `:2562–2574`, outside this path. The replan `children_effects` map is likewise not consumed by these point readers. Neither unused construction is an rrbvec candidate in this document. This statement is specific to replan; public structure/journal reads do use those collections elsewhere.

R3 changes the shared block/page bucket representation, not only the local replan builder. Adapt all point, tombstone and tree-candidate readers and snapshot producers listed above. Keep unrelated outbox and children collections outside the vector conversion scope. The existing bulk `index_effects` uses a right fold and prepend, which is already linear in memberships for sequence construction; construct each block/page vector bucket once at the producer, without per-lookup conversion or forcing the children index into the same representation. Preserve Map key semantics, chronological effect application and first-match behavior. Verify ordinary block/page and structure reads as well as replan, since those consumers bear the conversion cost even when no replan occurs.

An alternative is to store reversed Lists and redesign consumers to replay them in the required order. That can also eliminate append copying, but changes the iteration/search contract across shared readers and requires attention to right-fold stack behavior and first-match semantics. rrbvec supports the current forward-order contract directly. It is a suitable representation, not a proven winner over that alternative without measurements.

**Risk: medium/high.** `outbox_record` contains mutable fields. A persistent vector does not make its payloads immutable. Preserve required record freezing in `frozen_outbox` and snapshot isolation; do not remove payload copies because the outer sequence shares structure.

## Alternatives considered

### Queue for R1

A queue fits append and acknowledgement, and should be compared if those dominate actual usage. rrbvec also provides efficient retained subranges for pagination.

### Array for R2

An Array gives fast indexed reads and slices that copy selected values. Persistent local edits or retained versions require copying or an explicit ownership scheme. rrbvec combines indexed access with structural sharing without mutable shared slot storage.

### Reverse-ordered Lists for R3

Prepending avoids bucket-copy costs. Realizing the benefit requires readers to consume the reversed representation correctly, without reversing it on every lookup. This is an alternative design, not a parallel representation to maintain alongside the vector.

One-shot builders, identity/set lookups, unused intermediate construction, and append sites whose full serialization/sorting immediately rebuilds the collection are outside the candidate list. Those independent optimization opportunities are not part of this proposal.

## Acceptance criteria

### Owner-level performance acceptance

The three candidates are supported by inspected owner/consumer paths. Native owner-level measurements are now available in the acceptance report; they establish allocation and retained-memory benefits, not a general application speedup. Synthetic integer append/index/slice results are not used to rank these owners or justify implementation.

For each proposed owner, compare the current implementation with a vector representation through the owning operation, including necessary boundary conversion:

| Candidate | Workloads | Required observations |
| --- | --- | --- |
| R1 | Repeated publication without ack; interleaved publication/pull/ack; small and large retained counts | Append time/allocation, full pull/ack latency, cursor-search cost and memory released after ack/resync. |
| R2 | Small and 512-slot states; windows at front/middle/end; local updates and splices with old states retained | Window/update time, allocated bytes and GC, complete geometry/render preparation, live memory across deletion/undo lifetimes. |
| R3 | Disjoint UUIDs and many records affecting the same UUID; normal and configured-limit outboxes | Bucket construction allocation, effect replay visits/time, total replan latency, ordinary block/page/structure-read latency and frozen-state memory. Count existing unused construction separately so its elimination is not credited to rrbvec. |

Use a monotonic timer, enough iterations to avoid timer-resolution effects, repeated samples with dispersion, and correct output/order checks. Report absolute values as well as ratios. Keep input construction, one-time conversions and per-operation conversions explicit. The selected operation should show a repeatable benefit beyond run variation without a material regression in its normal workload; lower append cost alone does not establish that result.

### Behavior and repository constraints

- Maintain the cursor/order/snapshot invariants documented for each owner. Use one internal representation and remove obsolete paths rather than adding compatibility layers, fallbacks or migrations.
- Before adding any bug regression test, identify the production state owner and attempt reproduction through public pure reducer events, completions, state and effects. If it reproduces there, add only pure reducer regression coverage. If it cannot, document the missing boundary and use only the narrowest public layer that executes the defect. Do not inject an already-incorrect external collection, bypass `.mli` files, duplicate the regression across layers, or move production ownership for test classification.
- R2 exposes pure state transitions. R1 retention currently belongs to the worker effect runner; R3 bucket construction/replay belongs to `Database`. These ownership facts guide reproduction attempts, but do not substitute for actually attempting the public reducer boundary.
- Preserve existing relevant tests. For a subsequent implementation, run the selected owner suites and appropriate build checks; document-only work requires document validation rather than production tests.
- The implementation declares and pins `rrbvec` in the authorized Dune/opam dependency closure. The user explicitly authorized the three library Dune edits and their `dune-project` package declarations. No `spec/` OCaml changes are needed or made. Any future required spec change remains subject to the repository restrictions.
- Do not modify OCaml files in Bonsai Flutter. Verify this application's native macOS/iOS package closure rather than treating the installed opam pin as application-linking evidence.
- Follow `docs/ux-guidelines.md`; R2 changes the sequence implementation, preserving the existing UI components, retention limits and visible behavior.
- Transition this document to implemented only after the scoped implementation and acceptance checks are complete. Validate it with `spec-dev-tool check <doc-path>` and `spec-dev-tool check --all`.

## Consequences

- Structural fit does not establish workload importance. Bounded timelines, small buckets or frequently acknowledged windows may favor the existing List on constants.
- Full conversion on a hot internal read can erase vector benefits. Convert only a required selected page or at an unavoidable external boundary.
- Predicate searches, geometry computation, response encoding and effect replay remain separate costs. In particular, R3 can remain O(d²) overall for a repeatedly updated UUID.
- Shared sequence nodes and shared mutable payloads have different lifetimes and semantics. Measure retained memory and preserve snapshot freezing.
- The evaluated package remains a pinned development version. Native macOS/iOS application builds now verify its link closure; no application-wide frame or responsiveness speedup is claimed.

## Implementation record — 2026-09-07

- Initial baseline verification at `b32baf08ef0503cc84ab5df613607b058efa9e59` confirmed the three List owners before implementation.
- Baseline `dune build @all` and `dune runtest` both exited successfully before production changes. Dune may reuse cached test results; these commands establish the current build/test baseline, not vector acceptance or performance evidence.
- Worker runner state and overlay database/snapshot state are abstract in their public `spec/` interfaces. The inspected representation changes do not currently require exposing vectors there. Timeline's retained-slot accessor is in `app/journal_timeline_state.mli`, outside `spec/`.
- Applied the reviewed dependency patch after authorization: `app/dune`, `logseq_db_worker/lib/effect_runner/dune`, `logseq_overlay_db/lib/dune`, and the corresponding `dune-project` package declarations. Opam declarations and transitive locks carry the exact Git pin; `opam lint` passes.
- R1/R2/R3 now use vectors and adapted consumers. The obsolete Timeline List accessor is removed. Exact cursor comparison, snapshots, mutable payload freezing, and all matching point replacements are preserved.
- TDD evidence: the public Timeline state test failed on the List implementation at 1,557 new retained words and passes the 600-word sharing limit with vectors. Additional preservation tests cover Worker pagination/resync and chronological Overlay replay with a frozen snapshot. Existing tests remain in place.
- Final `dune build @all`, `dune runtest`, registered macOS regressions, macOS application build, and unsigned iOS application build pass. Both native frameworks contain `camlRrbvec` symbols. Changed OCaml files pass formatting; three unchanged historical reproduction files fail the same check on the baseline and are documented separately.
- [Owner measurements](../../../test-reports/2026-09-07-rrbvec/measurements.md) compare seven samples per workload, discard the first, and report dispersion, absolute time/allocation, ratios, checksums, GC and live memory. [Diagnostic allocation profiles](../../../test-reports/2026-09-07-rrbvec/README.md#r3-overlay-effect-buckets) separate bucket copying from unchanged effect replay. The selected allocation benefits are repeatable; normal complete workloads do not show a material regression. Small-operation constants and non-speedup results remain explicit in the report.
- No OCaml file under `spec/` or in Bonsai Flutter was modified. The original UX component choices and 512/40/4 retention/window/overscan limits remain unchanged.
