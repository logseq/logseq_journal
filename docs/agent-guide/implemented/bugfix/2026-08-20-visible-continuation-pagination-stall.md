# Visible Continuation Pagination Stall

## Problem

The journal timeline can remain on a visible `"Loading more journal entries"`
row until the user scrolls. The behavior reproduces on both iOS and macOS.
Scrolling causes the continuation to be replaced immediately with journal
entries, which makes the failure look like a renderer or frame-scheduling
problem.

The loading row is a `Day_continuation` slot. Day and feed pagination is driven
only by the `visible_range_changed` callback: the application scans the visible
range plus logical overscan and starts at most one worker request. A completed
day request replaces one continuation and clears the pending request, but it
does not reevaluate the stored visible range for another continuation.

This becomes observable when one range contains multiple day continuations.
`Journal_timeline_state.request_for_visible_range` retains page continuations as
a fallback while scanning and therefore returns the last page continuation in
the scan window. After that request completes, an earlier continuation can
remain visible. If the painted range is unchanged, the renderer correctly
deduplicates it and sends no second callback. Scrolling changes the painted
range, producing the event that accidentally resumes pagination.

### Runtime evidence

The issue was reproduced with the debug macOS application against the current
graph, without scrolling before the first inspection. Dart VM Service
inspection reported:

- the varied sliver's last published range was `[0, 11)`;
- `totalCount` was `26`, `firstIndex` was `0`, and all `26` children were
  materialized;
- the mounted widget tree contained two `"Loading more journal entries"`
  rows, following the April 30 and April 29 journal sections;
- `EventBatchQueue` had no pending events;
- `ForegroundFrameLoop` was eligible, non-terminal, and held a scheduled frame
  callback;
- runtime presentations continued advancing.

These observations exclude an unpublished initial range, a stranded Flutter
event batch, or a stopped foreground frame loop. The renderer had published
the range and the runtime had consumed its event.

After one controlled scroll:

- the painted range changed to `[12, 20)`;
- the sliver local revision advanced from `5` to `23`;
- `totalCount` increased from `26` to `36`;
- neither loading row remained mounted.

The observed transition matches a new range event restarting application-owned
pagination. It does not match recovery of a stopped renderer or runtime.

### Framework contract

The current bonsai_flutter virtual-list contract defines
`visible_range_changed` as the painted logical range. Unchanged ranges are
deduplicated, and consumers own materialization, effects, and pagination. A
widget update with the same painted range is not a new pagination signal.

The application currently treats this edge-triggered callback as if it were a
level-triggered assertion that all demand inside the range will eventually be
drained. That contract mismatch is the root cause.

## Decision

Make visible-range pagination level-triggered inside `logseq_journal` while
preserving the bonsai_flutter painted-range contract.

Store the latest bounded visible range as the authoritative demand window. Run
at most one pagination request at a time. After a successful `Feed_loaded` or
`Day_blocks_loaded` response is applied, reevaluate the updated timeline
against the stored visible range. If another `Day_continuation` or
`Feed_continuation` remains inside the visible range plus application overscan,
begin the next request immediately without waiting for another renderer event.

The drain must stop when:

- no eligible continuation remains in the demand window;
- a request fails or is rejected;
- the continuation cursor does not advance;
- the timeline or graph generation invalidates the response; or
- another request is already pending.

Continuation selection should prefer the earliest eligible continuation in
the demand window. `Children_loading` may retain higher priority because it
represents an explicit expansion action, but page prefetch must not select a
later continuation while leaving an earlier visible loading row unresolved.

The scope is limited to application pagination scheduling in
`app/journal_timeline_state.ml` and `app/application.ml`, plus focused unit and
runtime integration coverage. The renderer protocol, virtual sliver API, and
bonsai_flutter range deduplication remain unchanged.

## Alternatives considered

### Re-emit unchanged ranges from bonsai_flutter

Rejected. The documented callback represents painted-range changes, not
content revisions or effect completion. Re-emitting when `localRevision`,
children, or extents change would make pagination depend on renderer update
frequency, weaken event deduplication, and can create render/event feedback
loops for consumers that update state on every callback.

It would also hide rather than solve the application invariant: one demand
window may require multiple serialized requests.

### Preserve one request per event but select the first continuation

Selecting the earliest continuation improves the immediate symptom because a
visible loading row is handled before later prefetch work. It is not sufficient
as the complete fix. Two small continuation pages can still leave another
continuation in an unchanged range, with no event available to schedule it.

Earliest-first selection should accompany response-driven draining, not
replace it.

### Load every continuation eagerly

Rejected. Loading all retained continuations ignores viewport demand, defeats
bounded pagination, increases graph-worker traffic, and risks unbounded startup
work for large journals.

### Add a consumer-callable range replay API to bonsai_flutter

Rejected for this bug. An explicit replay API would still require the consumer
to detect that a completed response left unresolved demand. Once the consumer
does that, it can start the next request directly without a renderer round
trip. Such an API would add a second scheduling mechanism without resolving
the ownership issue.

## Acceptance criteria

- Given two eligible day continuations in one visible-range-plus-overscan
  window, one `visible_range_changed` event eventually loads both through
  serialized requests without another renderer event.
- After applying a successful day page, the application immediately schedules
  the next eligible continuation from the latest stored visible range.
- The drain never has more than one pending worker request.
- A stale generation, failed response, rejected request, or non-advancing cursor
  stops automatic draining.
- An earlier visible continuation is not skipped in favor of a later page
  continuation.
- Opening the macOS and iOS applications on the reproducing graph replaces the
  initially visible loading row without tap, pointer, or scroll input.
- A compiled-runtime integration test covers multiple visible continuations
  and asserts that `"Loading more journal entries"` disappears without a
  gesture.
- Existing bounded-window, stale-event, cursor, and retained-slot tests remain
  green.

## Consequences

The timeline now retains the ordered requests discovered by the latest visible
range. Successful responses remove or advance the completed request, while
unresolved requests remain eligible even if inserting an earlier page shifts
their logical indices. A repeated cursor clears the automatic drain demand, and
stale responses remain fenced by the pending generation.

Draining multiple pages can increase startup worker traffic when several
continuations share a small viewport. The visible-range-plus-overscan bound and
one-request-at-a-time rule limit that cost. Page continuation order changes from
the previous last-fallback behavior to earliest-first behavior; explicit child
expansion requests retain priority.

The runtime fixture generator now provides a pagination fixture with two
continued journal days. The compiled macOS integration test uses that fixture
to verify that both loading rows disappear without a gesture. No renderer
protocol, virtual sliver API, bonsai_flutter source, `spec/` interface, or dune
file changed.
