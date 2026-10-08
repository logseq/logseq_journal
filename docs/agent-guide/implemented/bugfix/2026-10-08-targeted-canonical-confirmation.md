# Confirm a mutation with a targeted canonical read

## Problem

Confirming one changed block paginated a page tree until the requested root was encountered. Logical read count grew with unrelated page members and the confirmation needed coherent target and child data.

## Decision

`logseq_db_worker/contract/protocol.ml` and `.mli` expose `V2_get_block_summary`. Its runner reads the target block, page, and direct children from one captured Database snapshot through existing public APIs. `app/journal_graph_runtime.ml` uses this query after Capture, source edits, and status changes. It paginates only target children at `Protocol.default_page_size` (50); conflict reconciliation retains its existing page-tree path.

## Identity, pagination, and retained behavior

Target request epochs prevent an older confirmation from overwriting a newer target result. Every page carries generation, projection revision, and children scope revision. Version mismatch or a stale cursor discards accumulated children and restarts at most twice. The accumulator is `Rrbvec`; its final list conversion serves the existing projection and reference output boundaries.

The request retains the existing page-tree interest before execution so a structure change during confirmation remains observable. Successful canonical completion also retains the actual journal page and root/direct-child page mappings, revisions, and tag titles. It registers no new children interest and sends no extra immediate page-tree query. Blank roots preserve the existing completion/visibility behavior; an unrelated Timeline hiding change is not included.

## Regression boundary and validation

Runtime owns confirmation policy and its public events/effects reproduce the excessive page-tree query. Those regressions stay at that boundary. The new worker command receives narrow actual execution coverage for snapshot composition, direct-child paging, cursor invalidation, and reply byte limits.

The final runs passed 85 Runtime cases and 10 Worker scenarios. With 1,000 unrelated siblings and 201 direct children, the Worker returned exactly those 201 children in order over five pages, with matching versions. A request using the maximum 200-item page can exceed the existing response-byte budget and receives the existing typed error; the Runtime uses the existing default 50. One individually oversized result still fails visibly rather than retrying indefinitely.

`tool/run_native_regressions.py` now discovers bytecode dependency metadata before building all native libraries it will link. This prevents the helper from linking stale `.cmxa` assumptions after `dune ocaml top` updates interfaces.

## Alternatives considered

### Continue page-tree pagination

One edit remains dependent on unrelated page members up to the target's position.

### Read a block without children

Canonical child summaries include source and image metadata used by the existing Timeline projection. A partial block response weakens confirmation semantics.

### Add a Timeline-only removal event

Blank-root hiding is an existing separate behavior issue. This fix retains the existing event semantics instead of expanding user-visible behavior.

## Consequences

Childless confirmations issue one logical targeted query. A target with C children needs max(1,ceil(C/50)) query pages, independent of unrelated page members. This is a statement about query/effect count and returned records, not total CPU or physical SQLite bytes: the existing children query recomputes membership digests per page, and retained cache updates still have legacy traversal costs. These were not rewritten. The canonical source/child summaries and existing changefeed interests remain available after confirmation. No protected spec, Dune, native GUI, or external account changes are needed.
