# Continue Journal Pages Containing Only Children

## Problem

Physical iPhone acceptance with 500 roots and 135 children under the first root
stops the Journal at the first root and its first 63 child previews. The native
scroll bar reaches 100%; 100 swipes cannot reach later roots or a saved Capture.
Block detail pagination and persisted inserts work independently.

The Worker page-tree limit counts tree members. A valid continuation page can
contain only children. Journal_graph_projection produces no top-level entries
and no application cursor for that page. Journal_graph_runtime then publishes
an empty terminal day page, incorrectly exhausting the Journal.

## Decision

Keep the production request coordinator responsible for translating Worker tree
pages into visible Journal pages. For initial feed and day reads, follow the
Worker continuation when the projected page has no visible roots. Preserve the
original page, limit and request generation; publish only a visible page or true
exhaustion. Preserve stale-cursor failures and reset fencing. Do not change the
Worker protocol, tree-depth policy, renderer, or protected specifications.

## Production ownership and reproduction

Journal_graph_runtime owns pending Worker operations. Its public create, submit,
receive, reset and output interfaces allow deterministic reproduction without
I/O. Supply valid tree-member pages containing real children and opaque advancing
cursors; observe the incorrectly terminal output. This does not inject an already
incorrect projection. The downstream pure timeline owner cannot reproduce the
cause without that incorrect result. Add regression coverage only to the existing
journal_graph_runtime_locality_test boundary, with no duplicate storage, runner,
UI or transport regression. Existing device acceptance remains acceptance evidence.

## Alternatives considered

### Add a native Load more button

Rejected: the continuation has already been discarded before native rendering.

### Treat a child cursor as a top-level root ordering cursor

Rejected: it mixes tree traversal and sibling ordering semantics in timeline state.

## Acceptance criteria

- Valid child-only intermediate pages do not publish an exhausted day or feed.
- Consecutive intermediate pages preserve opaque cursors, limits and generations.
- True exhaustion, Worker failure and reset remain terminal and correctly scoped.
- Existing runtime and timeline suites pass; native iPhone Release builds.
- On the same physical fixture, Journal reaches later roots and saved Capture;
  status mutation targets the saved block, verified from the isolated outbox.
- No Dune, protected spec, bonsai_flutter OCaml, separator or Undo/Redo changes.

## Risks

- Sparse visible roots can require multiple sequential bounded Worker reads.
  Do not fan out requests or publish a partial terminal result between reads.
- Device evidence is distinct from pure boundary coverage and remote sync proof.

## Questions

- None. Repair the defect discovered during the authorized iPhone acceptance.

## Consequences

All five new public coordinator regressions failed before the implementation
because an intermediate child-only page emitted a terminal response. They pass
after the repair, alongside all 36 coordinator cases, dune runtest and dune build
@all. No downstream duplicate regression or protected interface change was made.

The signed iPhone fixture host now traverses all 500 original roots and reaches
the same Capture that was unreachable before repair. Native status selection
changes that exact block from Todo to Done. Read-only database inspection confirms
one Capture insert, its Todo and Done operations, one Append insert, and only the
intended child deletion. The other graph has no queued writes. The initial status
test needed an actual scroll inside the half-height picker; its failed attempt
and successful continuation are retained separately in batch 35 evidence.

The production app must link the newly built complete object when repackaged.
A direct Xcode rebuild alone retained its older staged native object; that
superseded package is not accepted as the repaired deployment.
