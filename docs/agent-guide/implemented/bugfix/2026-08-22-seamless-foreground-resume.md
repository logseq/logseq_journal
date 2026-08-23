# Seamless Foreground Resume

## Problem

Returning from the background currently replaces the populated journal timeline
with `Loading journal`, resets the timeline model, and then reconstructs the visible
feed. This looks like a complete application refresh even though the Flutter host,
the Bonsai runtime, the selected graph, and the application route were never
restarted.

Two independent paths can produce this reset.

First, every `AppLifecycleState.resumed` transition requests a fresh host calendar
snapshot. Native code increments `JournalPlatformEnvironment.generation` for every
snapshot, even when the local day, locale, time zone, and UTC offset are unchanged.
`app/application.ml` uses `(calendar.generation, calendar.local_day)` as its feed
edge key. A normal same-day resume therefore always starts `Load_feed`, replaces
the current `Journal_timeline_state.t` with `Journal_timeline_state.empty`, and sets
`feed_loaded` to false.

Second, foreground sync closes the old WebSocket, performs an HTTP pull from the
durable server cursor, and reconnects. If the pull applies a mutation, the worker
emits `Graph_invalidated`. The application responds by reloading the initial feed,
again replacing the timeline with an empty model and setting `feed_loaded` to
false. A resume can therefore cause one destructive reload for the calendar event
and another after sync catch-up.

The destructive reset has broader effects than a repaint:

- the populated sliver is temporarily replaced with a static loading view;
- `visible_first`, `visible_last_exclusive`, pagination demand, and the scroll
  anchor decision return to their initial values;
- expanded row IDs and loaded child previews are discarded;
- formatted day labels are cleared and the header temporarily falls back to
  `Date unavailable`;
- the later feed rebuild cannot reuse all of the logical timeline state even though
  direct sliver items have stable keys.

The `bonsai_flutter` foreground frame loop is not the source of the destructive
refresh. It correctly stops frame grants for `hidden`, `paused`, and `detached`,
retains an unresolved runtime update, and resumes with a new frame generation. The
application platform also does not replace `BonsaiFlutterRoot` on resume. The
problem is the application-level choice to treat a freshness generation and every
graph invalidation as reasons to discard visible feed state.

Cold start, graph selection, graph replacement, and terminal graph failure may
still use blocking loading or replacement UI. This exploration is limited to an
already-open graph returning from background to foreground on iOS or macOS.

## Decision

Adopt semantic lifecycle revalidation with stale-while-refresh presentation. A
foreground transition remains a reason to refresh calendar facts and revalidate
sync, but it must not itself be a visible-content identity change and must never
blank an already-populated timeline.

### Separate freshness from semantic identity

Keep `calendar.generation` as an ordering and response-correlation token. Do not use
it as the identity of the feed. Compare the previous and next calendar snapshots by
the facts that affect each consumer:

- an unchanged local day, locale, time-zone ID, and UTC offset updates the current
  instant and lifecycle generation without reloading the feed or reformatting day
  labels;
- a locale change keeps feed contents and projection unchanged but requests new
  localized day headings;
- a local-day change updates the meaning of today and requires a feed refresh;
- a time-zone ID or UTC-offset change invalidates projected creation times and also
  requires a feed refresh;
- the raw calendar generation continues to fence stale formatting responses and
  stale calendar events, but does not participate in the feed edge key.

This likely requires explicit semantic keys rather than another overloaded tuple,
for example a feed projection context and a day-label formatting context. The exact
types belong in implementation design, not in the host wire protocol. The host
should continue emitting fresh snapshots because capture creation time and resume
sync still need current facts.

### Distinguish initial loading from background refresh

Replace the single `feed_loaded` interpretation with explicit initial-load and
refresh state. Initial graph opening may show `Loading journal`. Once a feed has
been presented, starting a calendar revalidation or graph-invalidation read must
leave that feed mounted and interactive.

A refresh response must be committed atomically only if its request generation,
calendar semantic context, graph generation, and worker basis are still current.
Late calendar, feed, formatting, and invalidation responses must remain unable to
overwrite newer state.

Applying a refreshed initial feed must follow the refresh cause rather than one
global replacement policy:

- a sync-driven refresh that contains real graph changes keeps the old feed visible
  while reading, then atomically installs the new feed with the current
  `Reset_to_top` behavior and clears expanded parents;
- a local-day change keeps the user's current logical position while updating the
  meaning of Today;
- a time-zone or UTC-offset change immediately reprojects visible creation times
  while preserving the user's current logical position;
- a locale-only change preserves timeline state and replaces only formatted labels.

Calendar-driven refresh therefore needs a timeline operation distinct from the
current `apply_feed` behavior for `before_day = None`. Sync-driven graph changes may
reuse the reset semantics, but must defer the reset until the replacement feed is
complete instead of clearing visible content when the request starts.

### Keep foreground sync authoritative without blanking content

Retain the current worker-owned foreground handshake:

1. close and fence the old WebSocket;
2. HTTP pull from durable `applied_server_t`;
3. apply authoritative replay;
4. reconnect WebSocket.

Do not issue a calendar-driven feed read on a same-context resume. If HTTP pull
applies no mutation, the existing timeline remains unchanged and no feed read is
needed. If replay emits `Graph_invalidated`, revalidate the affected presentation
without entering initial loading state.

The first implementation may continue using a bounded full initial-feed read for
structural or truncated invalidations. It keeps the previous feed mounted until the
read completes, then atomically replaces the feed, resets to the top, and collapses
expanded parents. The invalidation already carries changed UUIDs and
truncation/category flags, so a later optimization can refresh only affected visible
pages or blocks. Targeted invalidation is not required for the first
seamless-resume fix because page membership changes and truncated UUID lists still
require a correctness-preserving fallback.

Coalesce overlapping calendar and sync refreshes. A day or time-zone change may
start a feed refresh before HTTP pull finishes; a subsequent higher worker basis
must supersede or extend that request rather than produce two visible replacements.
The application should have one owner for the latest desired feed presentation.

### Preserve application and renderer state

Resume must not recreate `BonsaiFlutterRoot`, replace the native runtime, change the
current route, discard Capture or Detail drafts, or change stable sliver keys. The
existing `bonsai_flutter` frame-eligibility behavior remains unchanged.

When refresh fails after a feed has been presented, retain the last visible feed and
surface the existing non-blocking sync error treatment. Only initial load without
usable content may use the blocking graph/loading error state.

### Resolved product decisions

- Real graph changes use an atomic full-feed replacement, reset scroll to the top,
  and collapse all expanded parents after the new feed is ready.
- A local-day change while backgrounded preserves the user's current position
  rather than jumping to the new Today section.
- Foreground revalidation failure preserves the stale timeline and uses the existing
  inline sync error.
- A time-zone or UTC-offset change immediately and seamlessly reprojects all visible
  timestamps.

Likely implementation surfaces are:

- `app/application.ml` for calendar classification, refresh ownership, and loading
  presentation;
- `app/journal_timeline_state.ml` and its `.mli` for calendar-refresh continuity
  and sync-driven replacement semantics;
- `app/journal_graph_runtime.ml` only if feed refresh correlation needs stronger
  context or basis fencing;
- `test/application_view_test.ml`, `test/journal_timeline_state_test.ml`, and
  `test/logseq_db_worker_application_integration_test.ml` for lifecycle, timeline,
  and invalidation behavior;
- Flutter host tests only to verify that resume emits one fresh calendar event
  without replacing the runtime.

No `spec/` OCaml file, Dune file, `bonsai_flutter` repository file, sync wire
protocol, or iOS background-execution capability is in scope.

### Implementation outcome

The application now owns feed presentation through semantic projection and
formatting contexts rather than raw calendar generations. Same-context calendar
snapshots update freshness facts without requesting a feed or localized labels.
Local-day and time-zone projection changes use a stale-while-refresh feed owner;
locale-only changes invalidate only the formatting context.

Calendar refreshes atomically replace a completed feed while preserving the
logical visible slot, expanded parents, loaded child previews, route state, and
stable row keys. Sync invalidations use the same generation-, graph-, context-,
and basis-fenced owner, but atomically reset the completed replacement to the top
and collapse expanded parents. A typed `Feed_failed` result correlates read
failures with their request generation so stale or unrelated failures cannot
cancel the current refresh. Refresh transport failures preserve presented
content and surface the existing non-blocking sync error.

The Flutter host lifecycle remains unchanged. Tests verify that resume emits one
fresh calendar event and does not prepare a replacement root runtime.

## Alternatives considered

### Use only `local_day` as the feed key

This removes the unconditional same-day calendar reload, but it does not handle
time-zone projection changes and does not fix the second destructive reload caused
by foreground sync invalidation. It is a useful part of the semantic-key approach,
not a complete solution.

### Use the existing `apply_feed` for every refresh cause

Leaving `feed_loaded` true would remove the `Loading journal` flash. The current
initial-feed application still resets visible range, expansion state, and anchor to
the top when the response arrives. That behavior is accepted for a sync-driven feed
whose graph data changed, but it violates the selected position-preserving behavior
for local-day and time-zone changes. Refresh causes therefore cannot all share this
replacement policy.

### Never reload the feed on foreground resume

Relying only on worker invalidations is correct for unchanged calendar context and
sync data, but misses local-day rollover and time-zone projection changes. It also
does not define how a real invalidation updates a visible timeline without a reset.

### Refresh only UUIDs reported by invalidation

Targeted reads can minimize work and should remain an optimization direction.
However, changed blocks can enter or leave a journal page, page metadata can change,
and `changed_uuids` can be truncated. A targeted-only design has no complete answer
for ordering, pagination membership, and broad invalidation flags.

### Recreate or snapshot the complete runtime on resume

The runtime already preserves state across frame ineligibility. Recreating it would
expand the problem to graph bootstrap, worker lifetime, native resource restoration,
and draft persistence while making the visible refresh worse. The fix belongs in
feed refresh semantics, not runtime replacement.

## Acceptance criteria

- A same-day, same-locale, same-time-zone resume never displays `Loading journal`,
  never clears the populated timeline, and does not issue a calendar-driven
  `Load_feed` request.
- A foreground HTTP pull with no applied graph mutation does not reload the feed.
- A foreground HTTP pull with an applied mutation keeps the old feed visible until
  one current refresh result is ready, then atomically replaces the timeline,
  scrolls to the top, and collapses expanded parents.
- A local-day change updates Today without an intermediate empty timeline and keeps
  the user's current logical position.
- A locale change updates formatted labels without reloading or repositioning the
  timeline.
- A time-zone or UTC-offset change immediately reprojects visible creation times
  without an intermediate empty timeline or position change.
- Timeline route, Detail/Capture state, message-composer native state, and stable row
  keys survive a normal resume.
- Late refresh and formatting responses cannot overwrite a newer calendar context,
  graph generation, request generation, or worker basis.
- Refresh failure after initial presentation retains usable content and exposes a
  non-blocking error; cold start without content retains the existing blocking
  loading/error behavior.
- Focused OCaml application and timeline-state tests cover same-context resume, day
  rollover, locale/time-zone change, sync with and without mutation, overlapping
  refreshes, failure, and stale responses.
- A Flutter lifecycle test verifies background-to-foreground frame eligibility and
  confirms that the root runtime is not recreated.

## Consequences

- Foreground calendar and sync revalidation can continue while the last usable
  timeline remains mounted and interactive.
- Calendar generation remains a freshness and stale-response fence, but no
  longer defines feed or formatting identity.
- Calendar and sync refreshes can supersede pagination and each other by request
  generation; a sync cause remains authoritative when refresh causes overlap.
- Full sync-driven invalidation still performs the selected reset-to-top and
  collapse policy, but only after the replacement feed is complete.
- Calendar-driven replacement retains loaded child previews. A future targeted
  invalidation optimization may re-read only affected parents or visible pages,
  but it is not required for this correctness fix.
- The application runtime payload now distinguishes correlated feed failures
  from unrelated local request rejection.

## Risks

- Stale-while-refresh deliberately shows the last known graph state while HTTP and
  graph reads are in flight. The UI must distinguish this from initial loading and
  must not claim that sync has completed early.
- Preserving a visible anchor for local-day and time-zone changes requires a
  logical-slot policy. Preserving a numeric scroll offset alone can move the user to
  unrelated content.
- A sync-driven graph change intentionally resets the user to the top and collapses
  expanded parents. This trades reading-position continuity for a simple,
  unambiguous presentation of materially changed graph data.
- Calendar and sync refreshes use different freshness domains. Incorrect coalescing
  could apply a current worker basis with an obsolete time-zone projection, or drop
  a necessary re-projection.
- The timeline currently serializes one pending request. Adding a refresh lane or
  supersession rule must not starve visible pagination and child expansion.
- Full-feed replacement remains bounded by the existing slot budget but may still
  generate a large patch after a real graph change. Stable logical keys should
  reduce native node churn, and tests or benchmarks should verify that resume does
  not regress frame latency.

## Questions

- None.
