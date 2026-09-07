# Snapshot Checksum Indexed Entity Enumeration

## Problem

Snapshot activation computes an authoritative checksum after importing a remote
snapshot into staging and again before persisting and activating the local
mirror. `Authoritative_checksum.entities_with_uuid` currently enumerates
`Datascript.Eavt` with only `a = block/uuid` bound, then deduplicates entity IDs
with `List.mem` over a growing list.

EAVT requires an entity prefix for an indexed range lookup. The current
Datascript implementation does not choose a different index automatically:
without that prefix it enumerates the index and filters by attribute. The
subsequent list membership checks make entity deduplication quadratic even when
every UUID-bearing entity appears exactly once.

The earlier offline audit observed a mirror containing 168,716 logical datoms
and 18,399 UUID-bearing entities. Unique-entity list membership alone requires
169,252,401 comparisons at that size. One instrumented checksum computation
took 1,488 ms; snapshot preparation took 1,989 ms. These are historical samples
from an isolated copy, not release p95 measurements or a new benchmark of the
current checkout. The second checksum call was identified in the production
call chain, not independently timed. Temporary evidence was retained under
`/tmp/overlay-db-audit-20260907/`; implementation must use reproducible fixtures
rather than depend on that directory surviving.

This cost affects first download and re-download after removal of the local
mirror. Existing-mirror startup, ordinary local saves and incremental
authoritative updates do not execute these snapshot checksum recomputations.

Relevant production paths:

- `logseq_overlay_db/lib/authoritative_checksum.ml`:
  `entities_with_uuid`, `eligible`, `tuples`, and `recompute`.
- `logseq_overlay_db/lib/database.ml`:
  `prepare_snapshot_activation` and `persist_snapshot_activation` invoke
  `recompute`; `commit_snapshot_activation` publishes the prepared mirror.
- `logseq_db_worker/lib/effect_runner/effect_runner.ml`:
  `handle_sync_worker_effect` handles `Activate_snapshot` by calling the public
  Database activation API, supplying plaintext batches, and committing.
- `logseq_overlay_db/test/test_overlay_storage.ml` contains the existing public
  snapshot activation, cancellation, retry and checksum mismatch tests.

The current Worker passes `expected_checksum=None`. Preparation still computes
the first digest, but in this case neither compares nor retains it. When an
expected checksum is provided through the public API, preparation compares the
digest and rejects a mismatch. The second computation supplies the durable
checkpoint checksum. This distinction matters when considering removal of
redundant work; the first computation is not always a server integrity check.

## Decision

### Confirmed scope

Replace entity enumeration with an attribute-prefixed AEVT range and adjacent
entity deduplication. Keep checksum inputs, eligibility, hash arithmetic,
and normalization unchanged. Also skip preparation recomputation when
`expected_checksum=None`: there is no expected digest to compare, and the
computed result would otherwise be discarded.

On 2026-09-07, the user confirmed inclusion of this skip in the initial fix.
Preparation must still compute and compare a checksum when an expected value
is supplied. Persistence must still compute the checksum for the final local
database and store it in the durable checkpoint. The user requested transition
to proposed on 2026-09-07 after resolving the scope question. This decision records the agreed scope, now implemented and verified as
documented in the implementation outcome below.

With `a = block/uuid` fixed, AEVT orders the remaining fields by entity, value,
and transaction. Every datom for a given entity is therefore contiguous,
including physical duplicates. Remembering only the previous entity removes
duplicates without a hash table or a growing membership scan.

Implemented enumeration:

```ocaml
let entities_with_uuid db =
  let _, entities =
    Datascript.datoms db Datascript.Aevt ~a:"block/uuid" ()
    |> Seq.fold_left
         (fun (previous, entities) (datom : Datascript.datom) ->
            match previous with
            | Some entity when Int.equal entity datom.e ->
              previous, entities
            | _ ->
              Some datom.e, datom.e :: entities)
         (None, [])
  in
  entities
;;
```

Let D be all graph datoms, R the datoms in the block/uuid attribute range,
including duplicates, and U the distinct entity IDs in that range. Current
enumeration costs O(D + R*U), becoming O(D + U^2) when R=U. The intended
enumeration cost is approximately O(log D + R), with O(1) deduplication state
beyond the O(U) returned list. Physical duplicate merging inside Datascript
must be included in measurement rather than assumed to be free.

For a fixed attribute, the selected EAVT subsequence and AEVT range have the
same entity/value/transaction ordering. Prepending unique entities therefore
preserves the existing returned order. The final checksum also sums tuple
digests rather than hashing the entity traversal sequence.

The helper `datoms db ~e ~a` should continue using EAVT: it binds a valid entity
and attribute prefix. There is no blanket replacement of EAVT access.

### Conditional preparation checksum

Branch on `expected_checksum` before invoking `Authoritative_checksum.recompute`:

- `None`: proceed with the existing prepared activation state without computing
  a preparation digest. Do not replace it with another full-graph validation
  pass, a placeholder digest, or deferred computation that is still forced
  during preparation.
- `Some expected`: compute the digest using the existing E2EE mode and compare
  it with the supplied value. Keep mismatch rejection and staging cancellation.

For a successful activation without retries, the intended checksum execution
counts are:

| Expected checksum | Preparation | Final persistence | Total |
| --- | ---: | ---: | ---: |
| None | 0 | 1 | 1 |
| Some expected | 1 | 1 | 2 |

Do not reuse the supplied expected value as the durable checkpoint checksum.
Compute that checksum from the final database after any staged plaintext
application, using the existing persistence and retry memoization behavior.
Import validation, graph admission and decryption remain in place. A malformed
value previously discovered solely by the unused preparation checksum may be
reported later; validate cleanup and publication behavior at that later failure.

### Behavioral boundaries

- Preserve E2EE checksum inputs: UUID, parent, page and order. Preserve title
  and name inclusion for non-E2EE checksums.
- Preserve eligible-entity rules, reference UUID normalization, tuple-set
  semantics, UTF-16 handling and 32-bit arithmetic.
- Continue deduplicating by entity ID, not UUID value. Do not add new data
  validation or silently reinterpret malformed graph state in this fix.
- Preserve expected-checksum mismatch rejection, checkpoint publication,
  staging cleanup and activation retry behavior. With no expected checksum,
  checksum-only input failures may move from preparation to a later phase;
  do not publish a mirror when the final checksum or persistence fails.
- No protocol, schema, public API, UI, compatibility layer or migration is
  proposed. No OCaml files under `spec/`, dune files, or OCaml files in the
  bonsai_flutter repository need to change for the confirmed scope.
- Attribute-hydration caches, incremental checksum maintenance and unrelated
  overlay read/write optimizations are outside this decision.

### Production owner and verification boundary

The computational owner is the private `Authoritative_checksum` module,
executed by the public `Database` snapshot activation operations. The Worker
effect runner delegates to those operations. A reducer can schedule activation
and consume its completion, but the current inspected boundary does not expose
the checksum entity traversal as pure reducer state or effects.

Before adding any regression test during implementation, attempt reproduction
through the owning public pure reducer events, completions, state and effects,
as required by AGENTS.md. Record that attempt and its result; this document does
not claim a new executable reducer reproduction was run. Supplying a slow or
incorrect completion would only simulate the outcome and is not reproduction
of the index selection or quadratic enumeration.

If that boundary cannot execute the defect, document the missing computational
ownership boundary and use the narrowest existing public Database snapshot
activation tests. Do not expose the private checksum module, bypass an `.mli`,
copy its implementation into a test, move production ownership, or add duplicate
Worker integration/E2E/UI coverage. Existing tests remain in place.

Use literal expected checksums from independently checked small fixtures and
existing vectors for correctness. Capture the current real-snapshot digest for
before/after parity, without publishing private graph contents. Cover eligible
and excluded entities, repeated physical datoms where valid, multiple entities,
E2EE and non-E2EE inputs, and non-ASCII text. An empty eligible set should produce
the existing zero checksum; the overall fixture must still satisfy graph
admission requirements.

Exercise both `expected_checksum=None` and `Some expected`. For `None`, verify
that preparation does not invoke checksum recomputation and that successful
activation persists the independently expected digest. For `Some expected`,
cover matching and mismatching digests and retain pre-activation mismatch
rejection. Verify later checksum failures, cancellation and retries through
actual activation inputs, not injected incorrect completion results. These
control-flow checks follow the same production-owner rule as the enumeration
regression checks.

The old implementation already returns correct checksums on these ordinary
cases, so checksum parity alone cannot be a failing performance regression.
Reproduce the access amplification with actual index traversal/node-read
instrumentation around the public activation path. A count of returned UUID
datoms alone cannot distinguish an indexed range from full-index filtering.
If no suitable deterministic public instrumentation exists, record that gap
and use an isolated benchmark/profiler; do not introduce a forbidden spec or
dune edit merely to add counters.

Measure two independent dimensions: grow unrelated datoms while holding R
fixed, then grow R/U while keeping the remaining fixture shape comparable.
Separate import, checksum, decryption and persistence timing. Record allocation,
physical-node reads, traversal evidence and repeated wall-time samples. Use
source inspection together with growth measurements to verify removal of the
quadratic list membership work; avoid flaky wall-time assertions in unit tests.

### Implementation verification record

Before adding regression coverage, ran the existing public reducer scenario
`opam exec -- dune exec logseq_sync/test/test_sync.exe -- test 'pure core' 27`.
It passed. The scenario drives bootstrap events and typed runner completions to
`Delegate (Activate_snapshot request)`. The public request carries a staged
artifact, cursor and optional key; `Snapshot_activated` carries only the scope.
Neither boundary reads the artifact or executes the checksum. Varying graph
contents cannot exercise enumeration in this reducer. No incorrect completion
was injected to claim reproduction. Computational ownership remains private
`Authoritative_checksum`, reached through public `Database` activation operations.
Use that narrow public boundary for regression coverage and isolated profiling.

The installed Datascript source confirms attribute-bound AEVT exact-prefix lookup
and ordered merging of primary and physical duplicate datoms. It exposes no
public index-visit counter. Measure SQLite node restore callbacks and isolated
function timings/allocations, label returned rows separately, and use source
inspection to identify the full-index filtering path. Do not add a spec or Dune
counter interface.

Execution checklist:

- [x] Review scope, reducer ownership and active Datascript ordering.
- [x] Add all correctness/failure fixtures and capture behavioral RED plus baseline profiles.
- [x] Implement indexed adjacent deduplication and conditional preparation checksum.
- [x] Verify GREEN, parity, execution counts, retries and independent growth dimensions.
- [x] Review the final diff, run required checks and transition to implemented.

### Implementation outcome (2026-09-07)

Implemented both confirmed changes without changing persistence memoization,
checksum normalization, public interfaces, spec files or Dune declarations.
The actual malformed-input RED failed in unused preparation recomputation;
all 10 focused activation tests and the required overlay suite now pass.
Full `opam exec -- dune build @all` and `opam exec -- dune runtest` passed,
as did formatting, whitespace and decision checks.

The isolated public activation probe verified the conditional call-count table
and zero recomputation on publication retry. All 42 synthetic and 7 real-mirror
samples preserved before/after digests. With 1,700 UUID entities, adding 64,000
unrelated datoms changed new preparation enumeration node restores from 56 to 55
(old: 242 to 2,307); duplicate fixtures remained at 88 (old: 339 to 2,404).
Growing distinct UUID entities from 1,700 to 16,700 changed median enumeration
from 3.35 to 30.08 ms (old: 19.53 to 625.16 ms). These are instrumented local
samples, not release latency guarantees. Skipping preparation affects subsequent
cache warm-up, which is retained in the separate phase measurements.

See the [verification report](../../../test-reports/2026-09-07-snapshot-checksum/README.md)
for literal independently checked fixtures, reducer boundary evidence, actual
late checksum failure cleanup, source hashes, raw repeated measurements, profiler
limitations and self-contained synthetic reproduction commands. The production
Database diff was compared against the captured pre-task source to verify that
concurrent Page_tree changes were preserved.

## Alternatives considered

### AEVT with a hash set

This removes the same scan and quadratic membership problems and is valid if
enumeration order is not guaranteed. For the fixed AEVT attribute range,
adjacent deduplication is simpler and avoids O(U) additional set storage. The
selected implementation depends explicitly on the ordered index contract.

### AEVT without deduplication

Not selected. Logical UUID cardinality does not justify assuming physical
duplicate datoms can never appear. Processing one entity multiple times could
add its checksum contribution more than once.

### Retain EAVT and replace only List.mem

This removes the quadratic membership cost but still scans unrelated graph
datoms. It does not resolve the complete observed enumeration problem.

### Stream the checksum fold directly over the range

This could also remove the returned O(U) entity list. It changes more of
`recompute` than required to fix the two demonstrated defects and is deferred
from the agreed initial scope.

### Retain the unused preparation checksum

The current Worker supplies no expected checksum, and preparation discards its
computed digest in that case. Retaining it would preserve the earlier timing of
some malformed-input failures, but would keep an unnecessary whole-checksum
computation on the normal download path. The user rejected retaining this work
on 2026-09-07. Skip it for `None`, retain comparison for `Some expected`, and
validate the changed failure timing and cleanup rather than performing unused
work for incidental validation.

### Cache or incrementally maintain the whole checksum

Not selected for the initial fix. These approaches require additional reasoning
about changed roots, references, eligibility and activation phases; the indexed
linear enumeration fix does not require that state or invalidation machinery.

## Acceptance criteria

- UUID entity enumeration uses AEVT with a bound block/uuid attribute and has no
  full-index fallback caused by a missing entity prefix.
- Each distinct entity contributes once, including valid duplicate physical
  datoms; deduplication has constant work per returned range datom.
- Independently checked checksum fixtures and before/after snapshot checksums
  agree exactly, including E2EE exclusions and Unicode handling.
- Preparation performs no checksum recomputation for `expected_checksum=None`.
  Successful activation still computes and persists the final local checksum.
- Preparation with `Some expected` computes and compares the digest, accepts a
  match, and rejects a mismatch before activation with staging cleanup intact.
- Checksum execution counts match the conditional preparation table for
  successful activations without retries. Existing persisted-preparation
  memoization remains intact across activation retries.
- Errors discovered after skipping an unused preparation digest do not publish
  a partial mirror, and cancellation/cleanup remain effective.
- Measured enumeration does not grow with unrelated datoms except for index
  navigation/layout effects; increasing UUID entities no longer exhibits the
  prior quadratic membership trend.
- Preparation and persistence timing are reported separately. No claimed
  whole-checksum speedup is inferred solely from enumeration complexity.
- Existing snapshot activation, checksum mismatch, cancellation and retry tests
  pass. Run `opam exec -- dune runtest logseq_overlay_db/test` after the focused
  checks, and validate decision documents with `spec-dev-tool check --all`.
- Record the public reducer reproduction attempt and the chosen narrow test or
  measurement boundary before adding regression coverage.
- Implementation must not overwrite concurrent work, including the separate
  Page_tree decision and its source changes.

## Consequences

- Adjacent deduplication relies on Datascript preserving AEVT ordering while
  merging physical duplicates; verify the active library contract and fixture
  behavior before implementation.
- Faster enumeration does not remove the subsequent entity/property/reference
  reads. The earlier 1.49-second sample is a baseline, not a guaranteed target
  or a promise of proportional end-to-end download improvement.
- Physical-node caching and snapshot import can obscure the source of timing
  changes. Returned datom counts, index visits and SQLite reads are different
  metrics and must be labeled accurately.
- Benchmark data containing private graph contents must remain in isolated
  local copies. No remote graph writes are needed for this work.
- Skipping the unused preparation digest can defer an error to a later
  activation phase. This trade-off is included in the confirmed scope; final
  checksum failure must still prevent publication and permit cleanup.

## Questions

- Q1 (answered on 2026-09-07): Include skipping preparation recomputation when
  `expected_checksum=None` in the first implementation, alongside AEVT and
  adjacent entity deduplication. The user confirmed that a checksum with no
  expected value to compare does not need to be computed. Retain preparation
  comparison when an expected value exists and final checkpoint recomputation.
- No unresolved scope questions remain. The user requested the proposed
  lifecycle transition on 2026-09-07 and subsequently requested implementation.
  Implementation and acceptance evidence are recorded above.
