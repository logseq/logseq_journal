# Block Order Generation

## Problem

`Outliner_order` generated every order with `Printf.sprintf "a0%016x1" value`,
using the outbox sequence for roots and list indices for children. It ignored
existing sibling orders. Appending after `a0` and `a1` therefore produced
`a000000000000000011`, which sorts between them. The outbox sequence could also
restart when the outbox drained.

Block reads, child membership, and transactions independently reconstructed
orders. Nested insertion children were readable by UUID but were absent from
child membership indexes, preventing correct tail selection under a new tree.

## Decision

### Fractional-indexing contract

`logseq_overlay_db/lib/outliner_order.ml` implements pure `validate`, `generate`,
and `generate_n` functions through its `.mli`. It retains `compare_member` and
removes the old sequence/index generators.

The primary reference is `logseq.clj-fractional-indexing` revision
`1087f0fb18aa8e25ee3bbbb0db983b7a29bce270`, pinned by the local Logseq checkout's
`deps/db/deps.edn`. Logseq's `deps/db/src/logseq/db/common/order.cljs` delegates to
that library. The inspected implementation is:

```text
/Users/rcmerci/.gitlibs/libs/logseq/clj-fractional-indexing/1087f0fb18aa8e25ee3bbbb0db983b7a29bce270/src/logseq/clj_fractional_indexing.cljc
```

The implementation uses the base-62 alphabet
`0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz`, ordinary string
comparison, variable-length integer parts, string carry/borrow, and fractional
midpoints. It performs no floating-point arithmetic. Missing lower or upper
bounds leave that side open. Batch subdivision and midpoint rounding match the
pinned implementation exactly, except for the confirmed bug below.

Validation rejects empty or truncated keys, non-base-62 digits, invalid heads,
the reserved minimum integer, fractional suffixes ending in `0`, and equal or
reversed finite bounds. Integer keys such as `a0` and `b00` remain valid. Negative
counts are rejected; zero returns an empty list after validating the bounds.

| Bounds / count | Generated keys |
| --- | --- |
| No bounds, one key | `a0` |
| After `a0` | `a1` |
| Before `a0` | `Zz` |
| Between `a0` and `a1` | `a0V` |
| After `az` | `b00` |
| No bounds, three keys | `a0`, `a1`, `a2` |
| Between `a0` and `a1`, three keys | `a0G`, `a0V`, `a0l` |

### Allocation ownership and reuse

`Database.local_candidate_record` allocates orders once during insertion
planning. The root's lower bound is the greatest live logical child order of its
parent. Selection includes authoritative and preceding local children, excludes
tombstones, and examines the entire parent-local membership instead of a UI
page. No graph-wide maximum is used.

Each new parent receives an unbounded ordered batch for its children, assigned
in input-list order and recursively repeated for nested children. Different
parents can reuse keys. Neither UUID values nor outbox sequences participate in
the algorithm.

Assigned values are already present in the existing normalized transaction.
`Sync_tx_codec.inserted_orders` reads its UUID/order pairs; block hydration,
child membership, submission encoding, queued replanning, and authoritative
transaction comparison reuse these values. Reads never allocate keys. No
persistence field, codec version, migration, or compatibility path was added.

Insertion footprints include child interests for internal tree nodes. Structure
reads and parent-local bound selection therefore see nested children as well as
separately appended roots. Block reads, page-tree reads, paginated child reads,
and emitted transactions agree on each assigned value.

`Logical_snapshot` had no source callers. Its duplicate implementation and public
functions were removed. Empty `.ml` and `.mli` modules remain only because the
existing Dune file explicitly names this private module and this task does not
authorize Dune edits. They contain no order allocation or projection path.

### Confirmed reference bug and justified divergence

The user explicitly allowed divergence for a demonstrated upstream bug, with a
reproduction, corrected behavior, and focused regression. This bug was reported
to the user during implementation; it was not submitted to an external tracker.

Minimal reproduction against the pinned revision:

```clojure
(require '[logseq.clj-fractional-indexing :as f])
(def upper (str "A" (apply str (repeat 25 "0")) "1"))
(def key (f/generate-key-between nil upper))
;; => "A00000000000000000000000000"
(f/validate-order-key key f/base-62-digits)
;; throws: invalid order key: A00000000000000000000000000
(f/generate-n-keys-between nil upper 2)
;; throws the same error
```

The returned value is the library's reserved minimum integer. Although it is
lexically below `upper`, it violates the valid-key rule and cannot be reused as
an ordering bound, breaking repeated prepend/batch generation. A generator must
return a valid key strictly inside its bounds.

When decrementing would return that sentinel, this implementation instead
returns `A00000000000000000000000000V`. It is valid, below the upper bound, and
supports further prepends. The contract test verifies this exact correction and
an increasing five-key batch in the affected interval. Other valid inputs keep
the pinned reference's exact output; merely choosing a different valid key is
not treated as an upstream bug.

## Verification

### Production owner boundary

Before adding regressions, a temporary probe used the existing worker test's
public lifecycle events and completions to open a graph, then called
`Core.step` with `Graph_request` containing `V2_insert_blocks`. The only effect
was `Run_worker (Request (_, Execute_request ...))` containing the unchanged
request; public state reported one pending request. The reducer has no sibling
state or order allocation completion of its own. Its existing five tests passed.
The temporary probe was removed without retaining a duplicate reducer test.

The actual owner is `Logseq_overlay_db.Database`, which exposes commits and
snapshots rather than a public pure allocation reducer. Regressions therefore
exercise public Database operations in the existing `test_overlay_mutations.ml`.
They do not bypass private interfaces or inject an already incorrect result.

Before implementation, the append regression expected `a2` after authoritative
`a0`/`a1` and received `a000000000000000011`. The nested structure regression also
failed because children were missing. Both passed after implementation.

The four Database cases cover authoritative and local tails, deletion of a local
tail, unchanged existing orders, independent parents, nested sibling batches,
page-tree visibility, one-item child pagination, transaction/read equality,
230-child tail selection beyond the first 200-member page, reopening a pending
tree, and appending after equivalent authoritative data drains the outbox.

### Generator reference oracle

`tool/block_order_reference.clj` directly invokes the pinned library to generate
`test/fixtures/order/reference.tsv`: 1,911 cases across counts 0, 1, 2, 3, 4, 9,
and 32, including carry/borrow, prepend, narrow intervals, legacy valid long
keys, and maximum integer overflow. The fixture contains reference outputs,
not an OCaml algorithm copied into a test.

`tool/test_block_order.sh` compiles the production order module with its `.mli`
in a temporary directory and executes `tool/block_order_contract.ml`. This
standalone command is necessary because the generator is private and Dune edits
are outside scope. It must be run explicitly in addition to `dune runtest`.
It checks exact outputs, validity, strict bounds, cardinality, malformed inputs,
the corrected minimum boundary, a 4,096-digit narrow interval, and a 10,000-key
batch.

Run from the repository root:

```sh
sh logseq_overlay_db/tool/test_block_order.sh
dune build @all @runtest
rg --files -g '*.ml' -g '*.mli' -0 | xargs -0 ocamlformat --check
git diff --check
spec-dev-tool check --all
```

Regenerate the reference fixture with:

```sh
bb -cp /Users/rcmerci/.gitlibs/libs/logseq/clj-fractional-indexing/1087f0fb18aa8e25ee3bbbb0db983b7a29bce270/src \
  logseq_overlay_db/tool/block_order_reference.clj \
  > logseq_overlay_db/test/fixtures/order/reference.tsv
```

Final results: the 1,911 reference cases and additional generator checks passed;
`dune build @all @runtest` passed, including all 21 mutation tests. Formatting
passed for every changed OCaml file. The whole-repository formatting scan checked
238 files and found three existing, unchanged historical probes that do not
conform: `docs/test-reports/reproductions/probe-m01.ml`, `probe-m02.ml`, and
`probe-overlay-delete.ml`. No unrelated formatting edits were made.

## Alternatives considered

### Sequence formatting, numeric gaps, or the complete wrapper

Shorter sequence-derived strings still ignore sibling bounds and restart with
the outbox. Numeric gaps or floating-point midpoints eventually exhaust spacing
or precision. Copying the complete Logseq order wrapper would introduce unrelated
global maximum tracking, custom alphabets, and property ordering.

### Reallocating during reads or replay

Reconstructing orders during reads or replay could move an existing local block
when the sibling set changes. Reusing the already stored normalized transaction
keeps its assigned value stable without expanding persistence scope.

## Consequences

`Insert_blocks` remains an append operation with no new insertion or move
commands. Valid existing keys remain normal bounds and are not rewritten.
Repeated narrow-interval insertions can grow keys; the implementation does not
truncate them. Deterministic fractional indexing does not guarantee cross-client
uniqueness, and duplicate repair remains outside scope.

This task changes no UI, `spec/` OCaml files, Dune files, or bonsai_flutter OCaml
files. It complies with `docs/ux-guidelines.md` without introducing UI behavior.
