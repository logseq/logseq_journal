# Child Loading Request Starvation

## Problem

Expanding a journal block can leave a permanent `"Loading direct child
blocks"` row even though the graph is healthy and no worker request remains in
flight. The failure is timing-dependent and is readily observable on macOS
when the expansion overlaps an existing day or feed pagination request.

The timeline owns one serialized `pending` request. Expanding a block inserts a
`Children_loading` slot immediately. If a page request is already pending,
`Journal_timeline_state.next_request` returns `None`, so the click handler
publishes the loading slot without submitting a child request. When the page
response completes, response draining considers page demand captured by an
earlier visible-range observation. That snapshot predates the expansion and
does not contain the new child request. The timeline therefore reaches this
stable but invalid state:

- the `Children_loading` slot is retained and painted;
- `pending_request` is `None`;
- `request_for_observed_range` returns `None`; and
- `next_request` returns the unsent `Children` request.

A later visible-range event or unrelated detail response can accidentally
resume scheduling, which explains why the loading row appears intermittent.
The normal child query path succeeds when no page request overlaps the click,
so the defect is not a missing child, graph query failure, macOS renderer
failure, or stopped frame loop.

The current application and state tests cover an uncontended expansion and
serialized child expansions, but they do not cover inserting child demand
while a page request is pending. The compiled runtime child-flow test also
creates and expands the parent only after the initial feed has settled, so it
does not exercise this ordering.

## Decision

Use one application-owned timeline request drain for both explicit child demand
and viewport-driven page demand.

The implementation derives the next request only after application state has
stabilized, in one Bonsai edge. Expansion and visible-range handlers now record
demand but never submit timeline requests directly. Accepted timeline
responses only apply their state transition; clearing `pending` causes the same
edge to select the next eligible request. This prevents tap and visible-range
events delivered in one Flutter event batch from overwriting each other's
request ownership through a shared stale snapshot.

The drain must inspect the current timeline state after every scheduling
opportunity rather than treating a visible-range snapshot as the complete work
queue. It must select work in this order:

1. an eligible retained `Children_loading` slot;
2. an eligible `Day_continuation` from the latest observed demand window; then
3. an eligible `Feed_continuation` from the latest observed demand window.

The drain runs after a block expansion and after applying any accepted
`Detail_loaded`, `Day_blocks_loaded`, or `Feed_loaded` response. It submits at
most one request, records that request as `pending`, and advances the request
generation only when submission succeeds. A response that clears one pending
request must immediately give the drain an opportunity to submit the next
eligible request.

Explicit child demand is represented by the retained `Children_loading` slot,
not by `visible_demand`. It remains eligible if the painted range is unchanged
or if page insertion shifts its logical index. Collapsing or otherwise removing
the owned loading slot cancels its eligibility. Stale responses must not remove
or complete a loading slot owned by a newer expansion epoch.

Automatic draining stops when no eligible work remains, another request is
pending, submission fails, a response is rejected or stale, a page cursor does
not advance, or the graph/timeline generation invalidates the work. The UI must
not retain a loading row for work that has been definitively rejected without
also exposing a truthful retry or error state.

This decision extends the scheduler described by `Visible Continuation
Pagination Stall`; it does not change the painted-range contract. Scope is
limited to timeline request selection and application response draining in
`app/journal_timeline_state.ml` and `app/application.ml`, plus focused state,
application, and compiled macOS runtime coverage. It does not change worker
protocols, `bonsai_flutter`, any file under `spec/`, or any dune file.

## Alternatives considered

### Add child requests to `visible_demand` during expansion

Rejected. A block expansion is explicit user demand, while `visible_demand`
describes a renderer-observed pagination window. Coupling the two makes child
loading dependent on whether the parent remains inside an old painted range
and requires every slot mutation to keep a second queue synchronized.

### Replay the visible range after inserting a loading slot

Rejected. The renderer correctly deduplicates unchanged painted ranges. A
content revision is not a new visible-range event, and manufacturing one would
reintroduce the render/event feedback problem rejected by the continuation
pagination decision.

### Allow a child request to run in parallel with pagination

Rejected. Parallel requests would require replacing the single pending
generation fence with a multi-request ownership model. The bug does not
require that additional protocol and state complexity; serialized draining can
preserve responsiveness by prioritizing explicit child demand at the next
completion boundary.

### Ignore expansion while pagination is pending

Rejected. Dropping a valid click makes the disclosure control timing-dependent
and gives no truthful feedback. The application can retain the expansion and
submit its child request as soon as the current serialized request finishes.

## Acceptance criteria

- Given a pending `Day` request, expanding a retained parent inserts exactly one
  `Children_loading` slot without starting a parallel request.
- Applying the accepted day response immediately selects and submits that
  parent's `Children` request without a visible-range event, tap, scroll, or
  other renderer input.
- The equivalent pending `Feed` ordering also drains the child request.
- Applying the matching `Detail_loaded` response replaces the loading slot with
  the persisted direct child previews and optional `More` slot.
- Multiple expansions drain serially without reusing expansion epochs or
  exceeding one pending worker request.
- Collapsing a parent before its queued child request starts removes that
  request from eligibility; a stale detail response cannot restore the
  collapsed children.
- Page demand still drains within the latest observed range after higher
  priority child demand settles, preserving the visible continuation
  pagination acceptance criteria.
- A deterministic application test covers the exact ordering `Day pending ->
  expand -> Day_blocks_loaded -> Detail_loaded` and fails if the child request
  is not emitted after the day response.
- A compiled macOS runtime integration test controls response ordering and
  verifies that `"Loading direct child blocks"` disappears without a gesture.
- Existing timeline state, application view, compiled runtime, stale response,
  bounded pagination, and source-boundary tests remain green.

## Consequences

Child requests take priority over page prefetch after the current request
completes. Repeated user expansions can delay pagination, but retained loading
slots and the one-request-at-a-time rule bound the work.

Timeline request submission is now a level-triggered consequence of stable
application state rather than an imperative action duplicated across event and
response paths. This adds one scheduler edge but removes the obsolete visible
range and observed range request selectors. Initial feed loading remains a
separate startup operation because it has no retained continuation slot.

A failed transport submission terminalizes the graph surface through the
existing truthful error path. Stale responses remain fenced by request
generation, and a collapsed loading slot is no longer eligible. The focused
state and application tests cover `Day` and `Feed` contention, cancellation,
serial priority, and resumption of page demand. The compiled macOS runtime test
uses a persisted expandable fixture while pagination is active and verifies
that the loading row disappears without another gesture.

No worker protocol, renderer contract, `bonsai_flutter` source, file under
`spec/`, or dune file changed.
