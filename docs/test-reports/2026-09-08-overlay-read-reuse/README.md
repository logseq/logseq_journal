# Overlay API call-local read reuse verification

## Outcome

Implemented the five selected reductions in `logseq_overlay_db/lib/database.ml`.
The public contract, Dune declarations, storage implementation, and third-party
libraries are unchanged by this work. The pre-existing Rrbvec worktree changes
were retained. All required access gates and the 182-test overlay suite pass.
There is an allocation tradeoff for very wide sibling groups, recorded below.

The fixture contains 100,000 blocks and **504,455 live datoms**. Before and after
runs produced the same canonical fixture SHA-256:
`a865e56ddc8e14720708b51bfc330c1b9104adb300828558b8fddebfa76bca91`.

| Public operation | Datoms before | Datoms after | Logical block builds before / after |
| --- | ---: | ---: | ---: |
| Empty blocks | 173 | 0 | 0 / 0 |
| One existing block | 222 | 45 | 1 / 1 |
| 64 existing blocks | 600 | 423 | 64 / 64 |
| 64 pages | 1,408 | 337 | 0 / 0 |
| Insert ten blocks, 256 siblings | 3,266 | 1,043 | 1 / 1 |
| Delete ten overlay-only blocks | 7,920 | 53 | 33 / 10 |
| Delete one authoritative block | 1,336 | 45 | 6 / 1 |
| Delete ten authoritative blocks with interleaved IDs | 7,699 | 126 | 33 / 10 |
| Delete root, comments area, descendant, and patch reference source | 3,867 | 128 | 15 / 4 |
| Insert with additional valid scope, 100,000 siblings across two parents | 601,740 | 400,028 | 1 / 1 |

The selected calls perform zero full ident enumerations after the change.
Definitions and missing definitions use call-local memoization instead of an
up-front catalog scan. The 64-page batch builds two distinct definitions,
compared with 128 definition builds before. Overlay-tree deletion builds six
definitions, compared with 231 before. The insertion target is enumerated once;
with the extra valid parent scope there are exactly two enumerations, one per
parent. Stale preconditions are still rejected.

The baseline initially reproduced all six historical selected datom counts
exactly. Required access assertions failed before implementation. The final
probe passes them all. `comparison.json` records that all **22 observable result
digests**, prepared protection plaintexts, and submitted wire transactions match
between before and after runs. These are comparisons of public return values
and submission interfaces, not private state injection.

## Ownership and implementation

Before adding access regressions, a temporary executable reused the existing
public Worker reducer fixture. It drove account/catalog/mirror/attach
completions and sent `Graph_request (V2_get_block ...)` to the open graph. The
result was exactly `Run_worker (Execute_request ...)`, with one pending request
and one pending effect; see `reducer-boundary.txt` and `reducer-boundary.py`.
The reducer owns routing, not the Datascript root or graph traversal. Returning
an already computed result through a completion cannot execute the repeated
reads. Database is therefore the narrowest public owner boundary that
reproduces this defect. No additional Worker, effect-runner, persistence,
transport, integration, UI, or E2E regression was introduced.

The implementation uses one `read_context` for a captured logical snapshot.
Metadata remains lazy; authoritative entity/UUID/presence caches are separate
from logical block/page results. Missing values are cached explicitly. Block
revision validation, deletion traversal, reference-title patches, page and
parent collection, candidate planning, and the logical-effect check share the
same pre-mutation view. Default-property deletion avoids eagerly computing an
unused hard-delete footprint. Existing default guards and holder patches remain
covered by the mutation suite.

Sibling digest and maximum order are accumulated together, retaining only the
summary. The structural reader seeks over payload fields and retains one EAVT
lookahead. That lookahead is needed to preserve the old exactly-one-value
eligibility check; it can also supply the next sibling's first structural
field. It never hydrates sibling payloads or property summaries for the digest
or maximum. Full datom inputs remain available to the existing Children
pagination consumer, which actually returns hydrated records. Dependency-shadow
eligibility shares `block_header` with full block hydration and therefore keeps
its stricter title, parent, and page requirements without loading properties.

## Lifetime and semantic evidence

- `get_blocks []` completes lifecycle validation without creating a context or
  hydration cache. Released snapshots and closed databases retain their errors.
- Every new table is allocated within a snapshot read callback or the serialized
  mutation-lock computation. Every structural cursor is allocated during that
  computation and fully consumed there. No new field was added to Database,
  snapshot, outbox, preparation, crypto request, subscription, or dispatch state.
- Contexts are not used after candidate publication. `retry_blocked` creates a
  separate context solely for its unchanged-view precondition check. Other
  before/after and preparation/application code does not receive this context.
- The isolated instrumentation tracks hydration caches, read contexts, and
  structural-reader closures with existentially packed weak references. After
  API completion, full major collection confirms they are unreachable, while
  returned records, old snapshots, and a preparation remain live. Instrumented
  GC is outside reported operation timing/allocation deltas; production does
  not perform explicit GC for this change.
- Repeated identical calls on one snapshot return identical values and consume
  identical logical work. Independent concurrent calls agree. An old snapshot
  remains unchanged after writes, a cached miss does not hide a later insert,
  and rendered page titles follow the new view. Typed-error contexts are also
  checked by the subsequent lifetime assertion. Exceptions and cancellation
  unwind the existing read protection/serialized computation without storing
  the context in cleanup callbacks or asynchronous work; this is verified by
  the ownership/control-flow review, not a claim of injected cancellation tests.
- Focused public probes cover authoritative and overlay-only trees, repeated and
  absent UUIDs, distinct page values sharing a definition, map/collection
  properties, changed page titles, interleaved IDs, wide parents, extra valid
  preconditions, stale preconditions, comments cleanup, incoming references,
  present/absent dependency shadows, and incomplete sibling records. Incomplete
  records with UUID/order still affect insertion order exactly as before.
- Existing suites retain mutation identity, normalized transaction/order,
  frozen deletion footprint, default-property error handling, notifications,
  synchronization conflict, snapshot, and persistence coverage.

## Measurement contract and costs

`audit_read_reuse.py` builds an isolated instrumented source copy using existing
Dune declarations. It never edits installed libraries or repository build files.
`datoms`, `seek_datoms`, and `rseek_datoms` count calls and every consumed sequence
element; `find_datom` counts calls and present results. The keys report the query
index and requested attribute, including field-boundary lookahead consumption.
Counts include repeated consumption and exclude internal index comparisons.
Entry counters record actual logical block/page reconstruction and property
definition loading by UUID/ident. Physical SQLite restore calls are separate.
The probe uses public Database operations and public fixture/storage APIs only
for setup. No `.mli` boundary is bypassed and no production algorithm is copied
into the probe.

Per-operation allocation deltas include instrumentation and any physical reads
caused by that invocation. Examples (KiB, rounded):

| Operation | Before | After |
| --- | ---: | ---: |
| Empty blocks | 1,897 | <1 |
| One block | 2,055 | 253 |
| 64 blocks | 2,210 | 2,204 |
| 64 pages | 10,454 | 2,136 |
| Insert ten blocks | 2,119 | 2,176 |
| Delete ten overlay blocks | 20,892 | 2,157 |
| Additional wide parent scope | 321,622 | 784,397 |

**Fewer consumed datoms do not imply fewer allocations in every operation.**
The wide admission still needs O(sibling count) structural work, including
bounded field lookahead and index seeks. The final implementation retains a
constant-size sibling summary/cursor rather than a full sibling record cache,
but its cumulative allocation is higher than the old bulk entity path in the
wide fixture. The probe emits an allocation tradeoff observation for this case;
it is not an unrequested latency/allocation acceptance gate. Preliminary point
lookups allocated about 1.43 GB for this operation; bounded EAVT lookahead reduced
that to about 0.80 GB. This work does not introduce a persistent index to remove
that remaining cost.

Required incoming-reference and default-property holder fanout also remains.
No selective replan, persistent structural index, cross-call pagination cache,
outbox persistence, checksum, tail, or mutation-coalescing redesign is included.

`before-process.txt` and `after-process.txt` report process peak RSS, including
fixture construction and the whole scenario. This is not per-call retained
memory. Plain runs disable logical instrumentation and forced GC and are stored
separately as `plain-before.jsonl` and `plain-after.jsonl`; their one-shot timings
are observations, not p95 claims. Revision-token reads used to prepare commits
remain outside measured commit calls, just as in the baseline. Physical cache
warming from those reads can affect allocation and timing.

### Separate plain timing samples

| Operation | Before (ms) | After (ms) |
| --- | ---: | ---: |
| 64 pages | 4.129 | 1.210 |
| Insert ten blocks | 3.122 | 2.595 |
| Delete ten overlay blocks | 7.595 | 1.027 |
| Additional wide parent scope | 196.049 | 209.924 |

These sequential, uninstrumented samples corroborate the main read/deletion
improvements but also show the remaining wide-parent tradeoff. The latter
allocated 255,154 KiB before and 708,814 KiB after without instrumentation.
Plain whole-process peak RSS was recorded in the accompanying process logs;
these values include setup and must not be presented as call-local cache sizes.

## Reproduction and verification

Run from this Git worktree:

```sh
python3 logseq_overlay_db/tool/audit_read_reuse.py /tmp/read-reuse-check
python3 logseq_overlay_db/tool/audit_read_reuse.py /tmp/read-reuse-plain --plain
dune build @all
dune runtest
ocamlformat --check logseq_overlay_db/lib/database.ml logseq_overlay_db/tool/read_reuse_probe.ml
spec-dev-tool check --all
```

For baseline reproduction, reconstruct the saved baseline Database source from
`environment.txt`'s commit plus `baseline-database.patch` in a temporary copy,
and pass that file with `--database-source PATH --baseline`. The patch records
pre-existing worktree changes, not this implementation. `before-inputs.json`
and `after-inputs.json` retain exact sampled source identities. The probe and
instrumentation contract are identical between those two runs.

Verification completed: affected read/mutation tests; all 182 overlay tests;
`dune build @all`; `dune runtest`; instrumented access/lifetime probes; separate
plain measurements; changed-OCaml formatting; `git diff --check`; and the full
agent-document check. Existing Dune, `spec/`, and bonsai_flutter files were not
modified by this task. Detailed full-run logs are retained in this directory.
