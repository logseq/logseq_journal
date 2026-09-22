# Refresh Child Continuations After Append

## Problem

macOS native acceptance loads 64 of 135 children, appends successfully, then Load
more fails with "The read continuation is no longer current." The saved child
and each graph's outbox are correct. Journal_detail owns the retained branch
cursor and pending read generation. Its public reconcile_children completion
accepts a fresh prefix but preserves the old revision-bound continuation.

A temporary public-interface reproduction creates a paginated detail, delivers
a valid refreshed prefix with a new opaque cursor, then requests Load_more. The
emitted request still contains the old cursor. No storage failure is injected.
Regression coverage therefore belongs only in the existing pure reducer suite.

## Decision

Use the continuation delivered with each authoritative refreshed prefix and fence
superseded pending reads. A correlated Append completion invalidates a partial
branch's previous continuation and pending read. Keep displayed children and the
newly appended identity; keep Load more reachable so a read can restart from the
first bounded page until a fresh background prefix arrives. Fully loaded branches
do not need a new read. Existing restarted-page merging retains appended children.

## Alternatives considered

### Retry only after the stale-cursor error

Rejected: this exposes an avoidable failure after a successful local write and
requires an extra user action despite already receiving a fresh continuation.

### Change the transport or rebuild all children eagerly

Rejected: the public pure owner reproduces the defect. Eager loading would remove
the bounded pagination behavior and create unnecessary work for large branches.

## Acceptance criteria

- A fresh prefix replaces the old opaque cursor; subsequent Load_more uses it.
- Partial Append completion cannot reuse an old cursor or accept its pending read.
- Restart remains visible and preserves the appended identity without duplicates;
  later pages place unloaded siblings before the appended child.
- Fully loaded Append does not introduce an unnecessary load.
- Existing public routes/reducer tests and registered macOS regressions pass.
- Native macOS Append after the first 64 of 135 children can paginate to all 136
  without a stale continuation error.
- No spec, Dune or bonsai_flutter OCaml edits. Undo/Redo and separators remain deferred.

## Consequences

Partial branches can restart a bounded prefix read until background reconciliation
supplies the fresh continuation. Displayed children remain visible until that
read completes; locally appended identities survive the restart. Superseded read
completions cannot restore an obsolete cursor or error.

## Risks

- Restarting a partial branch can require reading an already displayed prefix.
  Reads remain bounded; valid background reconciliation supplies a fresh cursor.
- A pre-refresh read arriving late must not restore an obsolete cursor or error.

## Questions

- None. This repair is within the authorized native UI implementation and acceptance.

## Implementation evidence

Both new public pure reducer cases failed for the expected cursor defects before
repair. The complete routes suite, registered macOS regressions, dune build @all
and dune runtest pass afterward. Actual native macOS Append at 64 of 135 loaded
children now paginates to all 136 in order without an error. Cold-start graph
selection and the earlier saved graph-specific Append were also verified.

See docs/test-reports/2026-09-16-native-swiftui-standardization/implementation.md,
Batch 32, and batch32-acceptance.json for evidence and remaining device gates.
