# Page-tree bounded reads verification

## Result and ownership

Page_tree now traverses ordered lightweight logical candidates until the cursor
window and one valid lookahead are known. Only selected blocks enter full logical
hydration and block revision generation. No page-tree collection revision remains
in the public spec, implementation, Worker contract/codecs/catalogs, App retention,
or delete preconditions. Children membership revisions, item/page revisions,
projection-bound offsets, and page-tree refresh interests remain.

`Database` owns the captured authoritative and overlay roots, logical candidate
eligibility, hydration, and serialized mutation admission. Public Worker reducer
replays of both Page_tree and Delete_blocks emit the unchanged Execute_request
instruction. It has no traversal or admission state that could reproduce these
Database defects. Supplying a wrong external completion would not be a pure
reproduction. See [the reducer trace](reducer-boundary.txt).

Database regressions use only public snapshots, point/structure reads, local
commits, authoritative preparations/completions, and sync transitions. App tests
exercise only its request-construction boundary; codec tests exercise only the
changed wire contract. Existing sync tests were retained. The submitted-shadow
case additionally checks Page_tree against the same public point read; its
preservation assertion passes on both the baseline and final implementation.
There is no new transport, runner, integration, E2E, or UI reproduction of the
Database defects. No private `.mli` boundary was bypassed.

## RED and correctness evidence

Behavioral RED failures were captured before the implementation:

- [Root-only deletion](red-root-precondition.txt) was rejected after inserting a
  descendant subtree that was absent from the earlier snapshot. The initial test
  fixture accidentally omitted its insertion parent; that setup was corrected,
  and this retained RED trace reruns the corrected test against the unchanged
  baseline Database implementation.
- [Protocol decoding](red-protocol.txt) accepted the obsolete page-tree write scope
  and rejected a Page_tree result without collection revision fields.
- [App request mapping](red-app.txt) still attached a page-tree scope to deletion.
- [The access probe](red-access.txt) returned one item while calling full logical
  block hydration ten times and generating three item revisions.

Final coverage verifies:

- Depth-first order, UUID order within sibling order ties, depths 0/1/64/512,
  windows of 1/2/200, offsets 1/200 and longer continuations, complete pagination,
  terminal lookahead, and exact block/revision equality with public point reads.
- Missing UUID/title/order/page fields, missing reference UUIDs, invalid ancestors,
  and tombstones do not occupy response slots. Two physical entities sharing a
  UUID resolve once. A repeated single-valued parent field makes the canonical
  record invalid, matching the baseline: the duplicate-identity fixture returns
  five unique valid nodes, not six or twelve.
- Old snapshots retain content, page titles, local effects, and pagination after
  local deletion, saves, and authoritative page changes. New projections reject
  old cursors. Existing shape reuse, invalid bounds, and the 10,000 offset ceiling
  tests continue to pass.
- Local journal creation and nested insertion hydrate logical page titles, even
  when that page does not exist in the authoritative root. Submitted dependency
  shadows remain visible after their authoritative entity disappears; see
  [baseline](shadow-before.txt) and [final](shadow-after.txt) runs.
- Deletion checks the caller's root revision and freezes the latest local subtree
  in the same serialized admission operation. The new test includes a locally
  inserted child and grandchild absent from the earlier snapshot. A stale root
  produces Target_precondition_conflict. Existing queued/submitted delete,
  new-remote-descendant, frozen wire footprint, receipt, and remote-winner tests
  continue to pass with the root-only helper.
- A remote page change after deletion can conflict with the frozen footprint and
  restore the remote block. The read test checks this existing behavior rather
  than expecting the local tombstone to survive that conflict.
- Save/task-status guards, insertion's Children guard, App conflict refresh, and
  page-tree change-interest reconciliation remain covered by existing tests.

## Measurement method

[environment.json](environment.json) records the baseline commit, source hashes,
compiler, build tool, and selected offline mirror page. The uninstrumented
baseline `database.ml` was checked byte-for-byte against that commit. Historical
numbers in the decision document were not used as fixed performance gates.

The [Python harness](../../../logseq_overlay_db/tool/audit_page_tree.py) copies the
three database packages, their existing build declarations, and storage fixture
to an isolated directory. It instruments public Datascript datom/query calls,
logical block hydration entry, authoritative block conversion, block revision
construction, page hydration, and SQLite node restore callbacks. The
[OCaml probe](../../../logseq_overlay_db/tool/page_tree_probe.ml) calls public
Database interfaces. It never sends requests or mutations to the remote graph.

`datom_rows` counts consumed API results, including repeated consumption, not
unique datoms or disk reads. `logical_block_hydration` counts function entries;
baseline entries can discover an invalid/missing block. On the final code every
entry corresponds to a returned item. SQLite counts are node restore callbacks,
not all SQL operations or physical storage reads. Every instrumented tree sample
made zero Datalog query calls.

Cold means the first tree read after reopening Database, with its normal startup
metadata already restored. OS disk caches were not flushed. Warm means another
read on the same captured roots after the first read and point-equivalence checks;
SQLite restores can remain nonzero because underlying caches are bounded. Each
row is a single sample, not a percentile or end-to-end App latency. Allocations
and elapsed time are captured around the public tree operation only.

The release probe uses the unchanged, uninstrumented production modules with
release builds and `-O3` probe linking. Release datom/query counters are unavailable
and represented as null, not measured zeros. Only their availability labels were
normalized in the saved release rows; timing and allocation samples are unchanged.

Caches are operation-local: candidate fields/entities, reference UUIDs, insertion
orders, property definitions, and actual logical page titles. Selected hydration
reuses cached identity fields and performs one complete entity-datom pass for
remaining content. That selected pass also consumes the identity datoms in its
EAVT range; these repeated results are included in the counters. No skipped or
lookahead candidate gets full property/status/rendered-page/revision construction.
There is no cross-request tree cache or complete-tree warm-up.

## Offline mirror

The input is a private copy of the prior audit's downloaded mirror. The selected
journal is `00000001-2026-0527-0000-000000000000`, containing 81 depth-1 and 269
depth-64 visible items in this checkout.

| Warm read | Datom results before → after | Logical block calls before → after | Item revisions before → after | Ident scans before → after | Instrumented ms before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Depth 1, limit 1 | 38,208 → 475 | 162 → 1 | 81 → 1 | 82 → 0 | 46.97 → 0.83 |
| Depth 64, limit 1 | 126,532 → 475 | 538 → 1 | 269 → 1 | 270 → 0 | 182.92 → 0.85 |
| Depth 64, limit 200 | 126,532 → 3,736 | 538 → 200 | 269 → 200 | 270 → 0 | 168.56 → 11.40 |

For cold depth-64 reads, SQLite node restores dropped from 371 to 54 at limit 1
and from 359 to 196 at limit 200. The final offset-200 continuation returns the
remaining 69 items, consumes 2,968 datom results, and constructs 69 block revisions.
Raw cold/warm/continuation timings, allocations, and counters are in
[mirror-before.jsonl](mirror-before.jsonl) and [mirror-after.jsonl](mirror-after.jsonl).

## Synthetic distributions and release timings

The fixtures include a 300-node chain, 400 tied/interleaved top-level siblings,
20 node properties sharing a reference target, malformed candidates, physical
UUID overlaps, nested local effects, and two growth controls. One control adds
5,000 unrelated rich entities interleaved with relevant entity IDs; the other
adds 500 descendants to an unvisited final sibling.

| Warm read | Datom results before → after | Logical block calls before → after | Item revisions before → after |
| --- | ---: | ---: | ---: |
| Narrow, depth 512, limit 1 | 126,983 → 243 | 608 → 1 | 302 → 1 |
| Wide, depth 1, limit 1 | 167,567 → 3,427 | 806 → 1 | 401 → 1 |
| Wide, depth 1, limit 200 | 167,567 → 8,601 | 806 → 200 | 401 → 200 |

The harness asserts equality of every non-storage access counter for the wide
prefix across both growth controls at depths 1, 64, and 512. Selected hydration
and revision counts equal result cardinality in every final instrumented sample,
including local effects and continuations. Global ident enumeration and
unrelated EAVT range seeks are absent. Raw results are in
[synthetic-before.jsonl](synthetic-before.jsonl) and
[synthetic-after.jsonl](synthetic-after.jsonl).

| Warm release read | Uninstrumented ms before → after |
| --- | ---: |
| Narrow, depth 512, limit 1 | 160.41 → 0.46 |
| Wide, depth 1, limit 1 | 177.34 → 5.06 |
| Wide, depth 1, limit 200 | 175.85 → 31.01 |

Release allocation samples are retained alongside timings in
[release-before.jsonl](release-before.jsonl) and [release-after.jsonl](release-after.jsonl).
A wide visited sibling group still requires lightweight enumeration and ordering;
with numeric offsets, a continuation can revisit earlier structure. The change
bounds complete content construction, not total work to O(limit).

## Repository benchmark and checks

The existing 100,000-block release benchmark was run with all declared outbox
sizes: 0, 1, 32, 128, 1,024, and 4,096. The exact jq gate expression from
`logseq_overlay_db/tool/test_performance.sh` passed for the retained combined
[benchmark result](release-benchmark-after.json); see [gate output](release-gates.txt).
This includes sample counts, latency/allocation/RSS gates, reopen, rebase, and
delete-conflict cases. A same-checkout 128-record
[baseline](release-benchmark-before.json) is retained as well.

Commands used from the repository root:

```sh
python3 logseq_overlay_db/tool/audit_page_tree.py /tmp/page-tree-audit
python3 logseq_overlay_db/tool/audit_page_tree.py /tmp/page-tree-release --release
python3 logseq_overlay_db/tool/audit_page_tree.py /tmp/page-tree-mirror \
  --mirror-support /tmp/overlay-db-audit-20260907/support-clean \
  --graph-id f5271dfc-897a-43c7-b116-04832d13b70b
dune exec --profile release logseq_overlay_db/tool/performance_benchmark.exe -- \
  --block-count 100000
dune build @all
dune runtest
spec-dev-tool check --all
```

Use a fresh output directory. `--baseline` records accesses without asserting the
new bounds and must be run from the baseline checkout. Baseline probes here used
source copies captured before implementation. No repository Dune files, OCaml
implementations under `spec/`, or bonsai_flutter source files were changed.
Only the two required overlay `.mli` contracts were changed under `spec/`, with
explicit user authorization. UI presentation and launch navigation were not
modified.

The full [runtest log](runtest.txt), the [final incremental run](runtest-final.txt),
and the submitted-shadow follow-up results are retained. Final validation also includes formatting on changed OCaml sources,
Python syntax, JSON validity, whitespace checks, and a source/codec audit for
obsolete Page_tree collection revision references.
