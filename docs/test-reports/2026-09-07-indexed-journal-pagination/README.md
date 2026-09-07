# Indexed journal pagination verification

## Result

Journal pagination now selects through descending AVET reads, restores complete
same-date UUID ordering, merges active local creations, and hydrates only returned
pages. Query bounds precede pagination. Journal collection scope revisions and
legacy journal offsets are removed across overlay-db, Worker, App, and protocol
fixtures. Children and page-tree revision/cursor contracts remain intact.

## Ownership and regression evidence

The public worker reducer was replayed from an open graph with a `Graph_request`
carrying `V2_list_journals`. It emitted `run-worker:Execute_request` with the
unchanged request. It owns dispatch and completion handling, without an index,
selection window, or page hydration state. See [the captured trace](reducer-boundary.txt).
An incorrect injected completion would not reproduce either database defect.

The functional database cases use only `Database` snapshot, local mutation, and
authoritative-batch interfaces. `Journal_graph_runtime.submit` owns conversion
from `Load_feed.before_day` into protocol bounds; its public request output is the
narrowest executable boundary for the App defect. No duplicate functional
regressions were added to worker runners, transport, UI, or E2E suites.

Observed RED failures:

- The App emitted `from_day = 20260907` instead of `0` for an older-day request.
- A valid legacy journal offset cursor was accepted.
- Changing the date bounds of a continuation was accepted.
- A same-date group spanning index nodes lost members when reverse seeking by
  the date prefix alone. Expanding the public fixture to 133 same-date candidates
  reproduced the omission. Supplying maximum entity and transaction components
  to the reverse-seek bound fixed the complete date group.

The final public regression covers date/UUID order, one-item and two-item pages,
large tie groups, local creation and authoritative UUID overlap, built-in and
malformed candidates, inclusive and empty ranges, mismatched bounds, malformed
and stale cursors, full page/revision equivalence, and calendar boundaries
including leap years, month/year transitions, and the first supported day.
Existing journal change-interest refresh, page write preconditions, and structure
cursor tests remain covered.

## Access measurements

These are instrumented offline reads on macOS, not end-to-end Flutter latency.
Each row is one operation, not a percentile. Storage cache warmth and concurrent
work affect latency; consumed datoms and hydration counts are the primary
locality evidence. SQLite restore counts include index-node storage access and
may grow with tree height; they are not a count of hydrated entities.

### Downloaded mirror

The mirror was copied from the previous audit's `support-clean` directory. The
original downloaded mirror was not modified. The earlier audit reported 174,899
consumed datom results for both limits 1 and 200, at approximately 450 ms.

| Read | Datom results | Full-page hydrations | SQLite restores | Time (ms) |
| --- | ---: | ---: | ---: | ---: |
| First page, limit 1 | 79 | 1 | 30 | 2.47 |
| First page, limit 200 | 3,129 | 200 | 612 | 48.28 |
| Continuation, limit 1 | 84 | 1 | 27 | 2.15 |

Raw final measurements: [downloaded-mirror.jsonl](downloaded-mirror.jsonl).
The original baseline remains in `/tmp/overlay-db-audit-20260907/measurements.json`
and `/tmp/overlay-db-audit-20260907/overlay-db-access-audit.md`.

### Synthetic distributions

Both graphs contain 12,050 journals, a 32-journal date group, two newer invalid
candidates, interleaved entity IDs, tags, and 20 node properties sharing one
reference target. The second graph increases unrelated entities from 12,050
to 100,000, split equally between ordinary pages and blocks interleaved with
journal entity IDs. Each graph is also measured after eight public local journal commits.
Fixture generation uses public Datascript/storage interfaces outside measured
reads and retains the normal schema and durable mirror metadata.

| Read | Datom results in both graphs | Full-page hydrations | Reverse AVET datoms | Time, smaller/larger graph (ms) |
| --- | ---: | ---: | ---: | ---: |
| First page, limit 1 | 338 | 1 | 35 | 4.15 / 4.58 |
| First page, limit 200 | 6,158 | 200 | 204 | 15.98 / 16.70 |
| Same-date continuation, limit 1 | 331 | 1 | 33 | 0.79 / 0.82 |
| After 10,200 results, limit 1 | 186 | 1 | 4 | 0.60 / 0.60 |
| Local intents, first page, limit 1 | 201 | 0 | 35 | 2.76 / 0.54 |
| Local intents, first page, limit 200 | 5,934 | 192 | 196 | 15.47 / 5.32 |
| Local intents, after 10,200 results | 186 | 1 | 4 | 0.72 / 0.55 |

The audit asserts equality of every non-storage access counter across graph
sizes, not only totals. First-page storage restores were 57/58 for limit 1 and
164/164 for limit 200. No named-page enumeration, global `db/ident` enumeration,
or unrelated EAVT range scan occurred. Shared definitions and reference UUIDs
are resolved within the operation.

Tie-group work is explicit: 35 AVET results comprise two invalid candidates,
32 same-date physical candidates, and one next-date lookahead. A continuation
revisits the complete 32-candidate date group plus that lookahead. A deep unique-
date continuation reads the cursor's date, the selected result, one valid probe,
and the following group's first datom. The audit asserts that no consumed date
is newer than the last returned date of the preceding page.

Raw final measurements: [synthetic.jsonl](synthetic.jsonl).

### Physical duplicates and schema rejection

A separate persisted fixture retains two physical copies of each journal-day
fact. Pagination returns all 512 distinct journals exactly once. The limit-1
read hydrates only its one selected page. A fixture whose journal-day schema has
`indexed = false` returns `Invalid_read_request` with zero data accesses.
See [edge-cases.jsonl](edge-cases.jsonl).

## Reproduction and checks

Run from the repository root:

```sh
python3 logseq_overlay_db/tool/audit_journal_pagination.py /tmp/journal-synthetic
python3 logseq_overlay_db/tool/audit_journal_pagination.py /tmp/journal-edges --edges
python3 logseq_overlay_db/tool/audit_journal_pagination.py /tmp/journal-mirror \
  --mirror-support /tmp/overlay-db-audit-20260907/support-clean \
  --graph-id f5271dfc-897a-43c7-b116-04832d13b70b
dune build @all
dune runtest
spec-dev-tool check --all
```

The Python harness copies the three database packages and their existing Dune
files into an isolated output directory, instruments consumed datoms, exact page
hydration, and SQLite restores, and links the probe against public interfaces.
It does not modify repository Dune files, installed dependencies, or
bonsai_flutter. The probe does not expose private overlay implementations.

Final `dune build @all`, `dune runtest`, formatting checks on all touched OCaml
files, Python syntax validation, `git diff --check`, and agent-document checks
passed. Existing unrelated worktree changes were retained.
