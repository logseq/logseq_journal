# Reconcile Capture With Paginated Timeline

## Problem

Native acceptance successfully captures an entry in a 500-root journal, but later
pagination ends in a native runtime failure. Journal_timeline_state inserts the
completed Capture before the continuation, then blindly appends subsequent pages.
An earlier page can therefore be placed after the captured entry, and a final page
containing that same identity can produce duplicate native row keys.

The production owner is Journal_timeline_state. Reproduce through its public feed,
Capture completion and pagination events before changing implementation. Only this
pure state boundary needs regression coverage if it reproduces the defect.

## Decision

Merge paginated entries with the retained suffix beyond the requested cursor, replacing overlapping identities with authoritative incoming entries and keeping each identity once.

Merge the incoming page with the retained entries beyond the requested cursor.
Keep the unchanged prefix structurally shared, sort the merged suffix and replace
overlapping identities with their authoritative incoming projection. Count each
identity once and preserve other days, continuations and visible anchors.

## Alternatives considered

### Ignore duplicate native row keys

Rejected: the timeline would still have incorrect ordering, stale projections and
counts. Its state owner must reconcile the Capture completion with pagination.

## Acceptance criteria

- Public pure regression reproduces incorrect order and duplicate identity before repair.
- Intermediate and final pages preserve sibling order, unique identities, actual
  incoming projections and accurate slot counts; neighboring days remain intact.
- Existing timeline tests, including long history and cursor/anchor cases, pass.
- Native macOS acceptance can Capture and then paginate without runtime failure.
- No spec, Dune or bonsai_flutter OCaml changes; Undo/Redo stays deferred.

## Consequences

The unchanged prefix remains structurally shared. The bounded incoming page and any locally retained suffix are sorted together; existing anchor and completion ownership remain in Journal_timeline_state.

## Risks

- Reordering a retained Capture can affect a visible anchor. Use the existing
  finish_change path and retain the unaffected prefix rather than rebuilding history.

## Questions

- None. This is a defect discovered in the authorized native UI acceptance.

## Implementation evidence

Public pure events reproduce ordering, identity and count failures before repair. Today and historical-day cases and the existing timeline suite pass afterward. Actual native Capture followed by pagination to root 500 and the captured entry succeeds; cooperative shutdown completes.

See `docs/test-reports/2026-09-16-native-swiftui-standardization/implementation.md`,
Batch 23 and its logs/source hashes. Existing registered macOS regressions and the
full unsigned iPhoneOS Release build pass. Physical iPhone acceptance remains open.
