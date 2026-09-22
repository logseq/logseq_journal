# Follow Mutation Refresh Pagination

## Problem

Native macOS acceptance with a valid 500-root journal commits a Capture mutation,
then displays "The captured block was not visible after commit." The runtime
refreshes only the first bounded page tree after mutation and assumes the target
must occur there. Capture appends to the journal, so that assumption fails for a
large day. Update confirmation and conflict refresh use the same first-page
assumption; delete conflict can incorrectly infer absence.

The production owner is Journal_graph_runtime's deterministic public submit and
receive state machine. It emits read/mutation requests and consumes completions;
no storage, network or native UI is needed to reproduce a committed target beyond
a valid first page with a continuation. Exercise that public interface before
changing production code. Do not add duplicate effect-runner or UI regressions.

## Decision

Follow the page-tree continuation until the target root is found or the read is exhausted. Retain earlier members in reverse order between reads and preserve explicit cursor failures.

Follow the existing page-tree continuation while the requested root has not been
found. Keep prior page members in request state so reconciliation represents the
same contiguous prefix, and stop on the target or exhausted continuation. Preserve
native cursor errors and existing missing-target outcomes. Do not replay the
mutation or guess cursor contents. No protocol/spec changes are required.

## Alternatives considered

### Increase the page limit

Rejected: all finite page limits can still exclude an appended target.

### Report success without reading the committed block

Rejected: the application needs the authoritative block revision, status and child
projection and must preserve existing missing/conflict behavior.

## Acceptance criteria

- Public state-machine regressions reproduce the first-page false failure before
  repair, using valid paged results rather than an injected incorrect outcome.
- Capture/update and conflict refresh follow cursor requests without repeating
  the mutation and return the target's actual projection on a later page.
- Reconciled prefixes retain earlier entries; exhaustion and cursor failures keep
  explicit failure/absence behavior and cannot loop indefinitely.
- Existing runtime tests pass; the real isolated native Capture flow succeeds on
  the valid 500-root fixture after the repair.
- No protected spec or Dune files change. Undo/Redo remains deferred.

## Consequences

Large journals may require multiple bounded reads after a mutation. The mutation itself runs once, and final projections retain the contiguous prefix needed by conflict reconciliation.

## Risks

- A target near the end requires multiple bounded reads. Retain members in reverse
  order across requests to avoid repeatedly copying the accumulated prefix.
- A graph change can invalidate a continuation. Preserve the worker's explicit
  error instead of silently retrying or converting it to success.

## Questions

- None. This repairs a confirmed failure in the authorized native mutation acceptance.

## Implementation evidence

Twelve cases fail before repair; all 26 runtime locality tests pass afterward. Native Capture succeeds against the valid 500-root fixture. Missing/cursor-error semantics remain covered.

See `docs/test-reports/2026-09-16-native-swiftui-standardization/implementation.md`,
Batch 23 and its logs/source hashes. Existing registered macOS regressions and the
full unsigned iPhoneOS Release build pass. Physical iPhone acceptance remains open.
