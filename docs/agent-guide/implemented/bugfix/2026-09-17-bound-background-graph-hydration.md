# Bound Background Graph Hydration

## Problem

Batch 24 native acceptance observes Worker request queue exhaustion after a
37-block subtree deletion. Journal_graph_runtime generates point refreshes for
all retained changed blocks at once, plus structure/feed refreshes and change
acknowledgement. Worker has 32 outstanding-response reservations. A valid change
window can therefore exceed transport capacity without any malformed response.

The public Journal_graph_runtime submit/receive/reconcile_push boundary owns
these requests and reproduces the burst without storage, a worker thread or UI.
Use only this pure state boundary for new regression coverage.

## Decision

Retain background hydration requests in the runtime and dispatch at most four
concurrently. The window is shared across overlapping changes and resyncs; it
leaves capacity for foreground mutations, reads and manager control requests.
Replenish it on actual completions, including failures, and route dependent
background reads through the same window. Foreground requests keep their existing
admission and do not wait behind a large background refresh. Reset clears queued
and in-flight ownership so old responses cannot resume old graph work. Preserve
request identity, all affected projections and explicit worker failures.

Announce feed refresh ownership as a runtime response when the refresh is planned,
not by inspecting only the immediately dispatched requests. A queued resync must
still establish the correct application feed generation before its reads finish.
The application reserves push request generations and handles this explicit
start event through its existing completion reducer.

## Alternatives considered

### Increase worker capacity

Rejected: larger graphs can exceed any finite capacity; background producers
must bound their work instead of relying on a larger global queue.

### Drop excess refreshes

Rejected: retained rows could show deleted or stale content indefinitely.

### Retry every mutation after Full

Rejected: mutations are unrelated to background fan-out and must not be replayed.

## Acceptance criteria

- Valid public feed and change completions reproduce the oversized burst before repair.
- A large window and overlapping windows drain all retained affected identities
  exactly once per window with at most four outstanding background reads.
- Read failures release capacity without swallowing failure information; repeated
  completions and unrecognized responses do not advance or duplicate work.
- Resync and dependent background reads use the same bound.
- Reset removes queued work; stale old completions cannot dispatch it.
- Foreground reads are still admitted while background hydration is pending.
- Existing runtime/application regressions pass. No Dune, protected spec or
  bonsai_flutter OCaml files change. Undo/Redo stays deferred.

## Consequences

Background reconciliation now drains through a shared four-request window. The
public state owner proves all 48 changed identities are processed, failures and
foreground reads remain explicit, resync follow-ups stay bounded, and graph reset
discards queued work. A separate confirmed-red lifecycle check verifies a queued
resync announces feed ownership before dispatch. All 31 runtime locality tests
and existing registered macOS regressions pass. macOS/iPhoneOS native validation,
full unsigned iPhoneOS Release build and native 135-child pagination/Append
acceptance pass. See batch 25 of the standardization implementation ledger.

The prior large native subtree deletion was not repeated in this batch. The
producer bound is proved at its public pure state boundary; physical-device
acceptance remains open.

Batch 27 subsequently verifies native deletion of a parent and 80 children in
an isolated graph. The UI returns to the remaining nine roots without the prior
queue failure; one queued deletion has exactly the expected 81-block footprint.
A subsequent Capture succeeds, both results survive process restart, and the
runtime shuts down cooperatively. This is native acceptance of the repaired
producer, not a duplicate regression suite or remote-sync acknowledgement.

## Risks

- Small batches add scheduling round trips. Four requests amortize that overhead
  while reserving most of the worker budget for foreground operations.
- This fixes reconciliation fan-out, not arbitrary concurrent producers in every
  service. Existing terminal handling for unrelated transport failures remains.

## Questions

- None. This repairs the confirmed failure in authorized native acceptance.
