# Keep Graph Selection Reachable During Startup

## Problem

Physical iPhone acceptance reproduces a dead end after Retry on a missing wrapped
key. With authentication pending, the error becomes Loading your graphs and the
Choose another graph action disappears. Another encrypted local graph is usable.

## Decision

Keep Choose another graph on authenticated selected-graph loading, restore,
opening and bootstrap presentations. Reuse the existing switch-graph command and
native button. Do not expose it during local deletion, signed-out startup or
startup without a selected graph. Preserve the initial automatic local restore.

Ownership investigation: Journal_startup.derive owns the phase, not rendered
actions. Its public snapshot inputs correctly produce Loading_catalog during
pending authentication. The sync public Graph_picker_requested event already
cancels the graph scope, detaches it and fences its completions. Neither pure
boundary constructs the missing presentation action. Exercise public derive
first in the existing Application native-event harness, then assert the rendered
button and its sole Return_to_graph_picker command there. Pending startup facts
are valid external state, not an injected faulty result. Add no duplicate reducer,
transport or persistence regression. Physical acceptance is retained as evidence.

## Alternatives considered

### Wait for authentication to time out

Rejected: this leaves a usable local graph inaccessible during a slow request.

### Change the startup phase or recovery owner

Rejected: the loading phase is accurate. Only the presentation omits an exit.

## Acceptance criteria

- The existing native harness fails on the absent action after public derivation
  correctly identifies catalog loading, local restore and bootstrap phases.
- Each selected-graph waiting presentation exposes the action and dispatches only
  Return_to_graph_picker; no-selection, signed-out and deletion cases omit it.
- On iPhone, Retry with authentication blocked retains a reachable graph picker
  and opens the alternate encrypted local graph, at normal and maximum text size.
- Native regression suite, Dune checks and signed iPhone build pass. No Dune,
  protected spec or SDK OCaml changes; Undo/Redo and divider work stay deferred.

## Consequences

The actual iPhone failure and Application native-event RED are retained. Public
startup derivation correctly identifies the waiting state; six final admission
and command cases pass at the presentation owner. All registered native tests,
Dune checks and both signed iPhone Release builds pass. Current physical tests
verify pending Retry to alternate encrypted local graph and restart at normal
and maximum text size. Both graph outboxes remain empty in each fresh fixture.
Production cold start also passes. Detailed evidence and retained earlier harness
failures are in batch 39 of the
[implementation ledger](../../../test-reports/2026-09-16-native-swiftui-standardization/implementation.md).

## Risks

- Returning to the picker intentionally abandons the current startup attempt.
- Controlled blocked authentication does not validate real remote authentication.

## Questions

- None. This repairs the recovery path within the authorized iPhone acceptance.
