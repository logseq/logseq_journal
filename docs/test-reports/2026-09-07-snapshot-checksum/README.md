# Snapshot checksum verification

## Result

UUID enumeration now requests the `block/uuid` AEVT range and deduplicates adjacent
entity IDs. Entity/property reads still use their valid EAVT entity/attribute
prefix. Preparation computes a checksum only when an expected digest is present;
final persistence recomputes from the final database and retains its existing
retry memoization.

All 42 synthetic and 7 private-mirror samples have identical before/after digests.
The mirror digest is `checksum:v1:b354899130018f49`. The private mirror and exported
snapshot remain in isolated local directories; this report contains no graph
content. The historical audit timing was not used as a performance threshold.

## Ownership and regression boundary

Before adding tests, replayed the existing public Sync reducer bootstrap scenario:
`opam exec -- dune exec logseq_sync/test/test_sync.exe -- test 'pure core' 27`.
It passed; see [reducer-boundary.txt](reducer-boundary.txt). That scenario reaches
`Delegate (Activate_snapshot request)` using public events and typed completions.
The request contains an artifact, cursor and optional key, and the activation
completion contains only the scope. The reducer does not read the snapshot or
own any checksum traversal state. Changing actual snapshot contents cannot
execute this defect there. An incorrect or delayed completion would only simulate
its outcome, so no such completion was added as a regression.

The computational owner is private `Authoritative_checksum`, called by public
Database activation. New regression coverage uses only the existing Database
storage test executable. Fixture construction uses public Datascript and storage
interfaces; no private `.mli` is bypassed and no checksum implementation is copied
into an OCaml test. Existing tests remain in place. There is no additional Worker,
runner, transport, integration, E2E or UI regression layer.

## RED and correctness

[red.txt](red.txt) records both new tests on the unchanged baseline. The literal
checksum vectors passed, as expected for a performance fix. The late-failure test
failed because preparation still computed the unused checksum and raised
`Invalid_argument("checksum input contains invalid UTF-8")` for an actual imported
malformed title with `expected_checksum=None`.

[green.txt](green.txt) records all 10 focused activation tests passing after the
change. Coverage includes:

- 16 vector combinations: E2EE/plain, nonempty/empty eligible set, physical
  duplicates/no duplicates, and supplied/absent expected checksum.
- Built-in entities, orphan entities and missing UUIDs excluded; page-tag
  eligibility, missing reference UUID normalization, parent/page/order, title/name,
  BMP and supplementary Unicode, and combining characters preserved.
- Distinct physical entities sharing a UUID contribute independently; repeated
  physical datoms with another transaction do not repeat an entity contribution.
- Literal expected digests checked again by reopening mirror inspection, with
  durable cursor validation. [vectors.json](vectors.json) lists the contributing
  tuples by entity (identical tuples from distinct entities intentionally remain).
  [verify_vectors.py](verify_vectors.py) independently checks UTF-16 units and
  uses the polynomial form of DJB to cross-check its iterative recurrence.
- Expected-checksum mismatch rejects before activation, publishes no mirror and
  removes staging files. Existing crypto, cancellation, stale activation and
  publication retry behavior passes.
- Actual invalid UTF-8 with no expected checksum now prepares successfully, fails
  final checksum on both commit attempts, publishes no mirror, and supports
  idempotent cancellation that removes all staging artifacts.

The isolated probe asserts successful checksum execution counts: `None` has
0 preparation calls and 1 final call; `Some expected` has 1 preparation call and
1 final call. Its publication failure/retry cases assert that the retry executes
zero checksum calls after the persisted preparation is cached.

## Measurement method and limits

The [Python harness](../../../logseq_overlay_db/tool/audit_snapshot_checksum.py)
copies the three storage/database packages and their existing build declarations
into an isolated directory. The [OCaml probe](../../../logseq_overlay_db/tool/snapshot_checksum_probe.ml)
executes the public activation operations. Source-only wrappers measure import,
enumeration, whole checksum and disk persistence without exposing private modules.
A counter in the existing SQLite restore callback measures storage node restores.
The harness does not modify repository Dune files, spec interfaces or installed
libraries. The baseline retains concurrent Page_tree changes; [baseline.patch](baseline.patch)
reverses only this fix in captured source copies. Environment JSON files record
source SHA-256 values and compiler version.

The installed Datascript `db.ml` selects `exact_prefix_datoms` for attribute-bound
AEVT; unprefixed EAVT falls back to `index_datoms_seq` and then filters. Its
`util.ml` comparator orders AEVT by attribute/entity/value/transaction, and
`exact_prefix_datoms` merges sorted primary and physical duplicate datoms.
[datascript-source.json](datascript-source.json) records the inspected source hashes.
No public index-visit instrumentation is exposed, so there is no exact visit-count
assertion in unit tests. SQLite node restores, returned datoms and source traversal
evidence are reported separately; restored nodes are not physical disk reads or
all SQL operations. Duplicate merging costs are included in the samples.

Each table reports medians of three wall-time samples from release builds with
measurement wrappers. Allocations include traversal, decoding and GC-visible
allocation inside the measured operation. The wrappers add overhead; these are
local samples, not release p95, exclusive-machine benchmarks or end-to-end app
latency. Some other builds/checks ran concurrently. OS caches were not flushed.
Preparation reads freshly imported storage; commit reuses the staged database and
its caches, with E2EE plaintext application potentially replacing the database.

The phase named `decryption` measures ciphertext enumeration, identity plaintext
supply and staging through the public batch API. It does not perform or benchmark
cryptography. The real mirror was already a local plaintext mirror. Final commit
also includes staged plaintext application, checkpoint work and publication, so
its duration exceeds checksum plus disk persistence. No full-checksum speedup is
inferred solely from enumeration complexity.

## Independent growth dimensions

The fixture names record added UUID entities and unrelated datoms. The base has
700 UUID entities, so the actual distinct UUID counts are 1,700, 4,700 and 16,700.
Noise entities have no UUID. Duplicate fixtures add another transaction for each
added fact, producing 2,700 UUID range datoms for 1,700 entities.

| UUID entities | Unrelated datoms added | Physical duplicates | Enumeration ms before → after | SQLite restores before → after | Allocated MB before → after |
| ---: | ---: | :---: | ---: | ---: | ---: |
| 1,700 | 0 | No | 19.53 → 3.35 | 242 → 56 | 26.55 → 5.75 |
| 1,700 | 64,000 | No | 161.15 → 3.63 | 2,307 → 55 | 271.73 → 6.65 |
| 4,700 | 0 | No | 72.51 → 8.99 | 533 → 152 | 64.09 → 19.70 |
| 16,700 | 0 | No | 625.16 → 30.08 | 1,695 → 539 | 207.80 → 71.88 |
| 1,700 | 0 | Yes | 25.11 → 5.29 | 339 → 88 | 38.14 → 11.01 |
| 1,700 | 64,000 | Yes | 167.29 → 5.15 | 2,404 → 88 | 284.23 → 12.84 |

These preparation enumeration samples use `Some expected` to retain both calls.
They show removal of unrelated-index scanning, including physical duplicates.
UUID growth measurements and source inspection together establish removal of the
growing `List.mem`: adjacent deduplication performs one entity equality check per
range datom. Index layout accounts for the small node/allocation difference in
the unrelated growth control. Raw phase timings, allocations, returned rows and
node counts are in [synthetic-before.jsonl](synthetic-before.jsonl) and
[synthetic-after.jsonl](synthetic-after.jsonl).

## Private mirror phase timings

| Phase, ms | None before → after | Some expected before → after |
| --- | ---: | ---: |
| Total preparation | 4,310.47 → 3,237.42 | 4,730.68 → 3,732.24 |
| Preparation enumeration | 1,038.81 → skipped | 1,075.64 → 33.29 |
| Preparation whole checksum | 1,314.16 → skipped | 1,359.91 → 711.03 |
| Identity plaintext supply/staging | 1,028.58 → 1,480.40 | 1,063.49 → 1,046.18 |
| Final enumeration | 671.10 → 1.38 | 704.12 → 1.16 |
| Final whole checksum | 818.72 → 155.48 | 856.25 → 151.89 |
| Final disk persistence | 309.89 → 328.52 | 375.43 → 309.79 |
| Total commit | 1,917.56 → 1,326.49 | 2,104.91 → 1,261.53 |

Skipping preparation changes cache warm-up for subsequent operations; the identity
plaintext staging increase in the None samples is retained rather than hidden.
The Some preparation checksum still performs entity/property reads beyond the
much smaller enumeration range. Raw measurements, including import timing, are in
[mirror-before.jsonl](mirror-before.jsonl) and [mirror-after.jsonl](mirror-after.jsonl).

## Reproduction and checks

From the repository root, use fresh output directories:

```sh
mkdir /tmp/checksum-baseline-source
cp logseq_overlay_db/lib/authoritative_checksum.ml logseq_overlay_db/lib/database.ml /tmp/checksum-baseline-source/
patch -d /tmp/checksum-baseline-source -p0 < docs/test-reports/2026-09-07-snapshot-checksum/baseline.patch
python3 logseq_overlay_db/tool/audit_snapshot_checksum.py /tmp/checksum-before --baseline-source /tmp/checksum-baseline-source
python3 logseq_overlay_db/tool/audit_snapshot_checksum.py /tmp/checksum-after
python3 docs/test-reports/2026-09-07-snapshot-checksum/verify_vectors.py
opam exec -- dune exec logseq_overlay_db/test/test_overlay_storage.exe -- test '.*' 2-9,12-13
opam exec -- dune runtest logseq_overlay_db/test
opam exec -- dune build @all
opam exec -- dune runtest
spec-dev-tool check --all
```

The optional `--mirror-database PATH --graph-id UUID` takes a consistent SQLite
backup from a read-only connection before any profiling. Synthetic reproduction
does not depend on the historical `/tmp` audit data surviving.

All listed test/build commands passed. Dune reuses previously successful unchanged
test aliases on the full run; [overlay-tests.txt](overlay-tests.txt) records the
required overlay suite and [runtest.txt](runtest.txt) the remaining invalidated suites.
The successful build emitted no warnings. OCaml formatting on the four touched
OCaml files, Python syntax, fixture JSON, `git diff --check` and decision validation
also passed. Only the checksum helper and preparation branch changed in production;
comparison against the captured Database source confirms no concurrent Page_tree
changes were overwritten. There are no new public API, protocol, UI, compatibility,
migration, spec or Dune changes in this fix.
