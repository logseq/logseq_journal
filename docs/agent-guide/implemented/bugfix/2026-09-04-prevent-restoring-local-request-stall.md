# Prevent Restoring Local Request Stall

## Problem

After a graph is selected and persisted, a terminated macOS application can
restore the graph database but remain permanently on `Loading journal`.
Diagnostics reports `Sync phase = Current`, `Startup phase = Restoring local`,
and `Graph phase = Open`. Returning to the graph picker and explicitly selecting
the same graph immediately loads Timeline, so the mirror, catalog, graph
lifecycle, and stored data are usable.

The warm-launch path starts three independent application-platform requests and
the Worker restoration concurrently. A restored graph can reach `Graph_open`
before Application has accepted its calendar snapshot. Timeline loading is
gated by `state.calendar`, while the sync core keeps
`timeline_presentation_pending = true` until Timeline has loaded and Flutter has
acknowledged its presentation. This creates a circular startup wait: the graph
is open and Sync is current, but no feed is presented and the core cannot leave
`Restoring_local`.

The issue is reproducible with the current macOS debug build. A process sample
shows an idle live application rather than a crash, focused reducer and Worker
protocol tests pass, and an explicit selection in the same process loads the
same graph successfully.

## Proposal

Make the calendar snapshot an explicit prerequisite of managed warm startup.
On activation, request and accept the initial calendar snapshot before sending
`Restore_local_account` or reconciling the authenticated user. Keep the
typography preference independent because it is not a Timeline data dependency.

The graph-open path must never depend on a calendar request that is merely
concurrent and may not yet have updated Application state. Once restoration is
allowed to start, `Journal_graph_runtime` must already have the same accepted
calendar snapshot that Application uses for its feed projection context. The
existing graph-info, feed-load, local-feed acknowledgement, Flutter presentation
acknowledgement, and sync-core transitions remain the only startup path.

Add a headless Application regression test that resolves warm-start platform
data under the problematic ordering and proves restoration remains fenced until
the calendar prerequisite succeeds. Follow TDD and use a manual
terminated-process macOS walkthrough to verify the complete Timeline outcome.

## Decision

Adopt calendar-first managed startup. A valid calendar response must update both
Application state and `Journal_graph_runtime` before local account restoration
or authenticated-user reconciliation can begin. A failed or invalid calendar
response does not start graph restoration. Typography preference loading remains
independent.

## Alternatives considered

### Retry calendar loading from `Graph_open`

Issue another calendar request whenever a graph opens without one. This can
recover the observed launch, but it retains two independent startup races and
allows duplicate calendar snapshots with different generations to compete. It
also treats a missing prerequisite as an incidental retry rather than enforcing
the ordering contract.

### Load the feed without a calendar

Synthesize a date or reuse stale process-local time facts. Rejected because day
selection, labels, request bounds, and capture timestamps require one coherent
host calendar snapshot. Application must not invent or partially reconstruct
those facts.

### Clear `timeline_presentation_pending`

Mark startup ready as soon as the database opens. Rejected because it would show
an empty or stale surface as ready and bypass the required local-feed and Flutter
presentation acknowledgements.

## Acceptance criteria

- A terminated macOS launch with a valid cached selected graph reaches Timeline
  without showing or requiring interaction with the graph picker.
- Warm restoration cannot send `Restore_local_account` before Application and
  `Journal_graph_runtime` have accepted the initial calendar snapshot.
- `Graph_open` leads to graph-info and initial feed loading with a defined feed
  projection context.
- The local-feed and Flutter presentation acknowledgements clear
  `timeline_presentation_pending`, and startup derives `Ready`.
- Missing or invalid cached selections still show graph selection, and explicit
  selection still opens the graph.
- Calendar refreshes after startup retain their existing generation fencing and
  formatting behavior.
- A headless regression test fails before the implementation and passes after
  it; focused tests, the complete suite, formatting, build, source boundaries,
  agent-document validation, and a macOS terminated-process walkthrough pass.
- No OCaml file under `spec/`, Dune file, Flutter fallback, compatibility path,
  cache migration, or bonsai_flutter repository file is modified.

## Risks

- Calendar acquisition is moved onto the critical path before local graph
  restoration. This adds the host calendar request latency to warm startup, but
  prevents graph work from starting without the data required to present it.
- A calendar host failure must not be disguised as successful graph restoration.
  Existing platform error handling remains sanitized, and the regression test
  must cover the successful prerequisite ordering rather than inventing calendar
  facts.
- Startup effects cross the Application-platform and Worker boundaries. A test
  that asserts only helper state or request counts would miss the real deadlock;
  verification must observe the rendered startup outcome.

## Consequences

Managed warm startup now includes calendar acquisition on its critical path.
Graph restoration begins slightly later, but every graph-open transition has a
defined feed projection context and can complete the existing Timeline
presentation handshake. A calendar host failure leaves graph restoration
unstarted instead of publishing a misleading `Restoring local` state that cannot
advance.

## Implementation outcome

Implemented on 2026-09-04.

- Application now decodes and applies the initial calendar response before
  releasing the existing managed-startup effect. Calendar events and startup use
  one shared application function, so Application and `Journal_graph_runtime`
  accept the same snapshot.
- Headless Application tests verify that local account restoration is absent
  before calendar completion, begins after a valid calendar response, and stays
  absent after a calendar host failure. The RED run reproduced the previous
  premature local-binding request before production code changed.
- Focused tests, `dune build @fmt`, the complete `dune runtest` suite, Flutter
  tests, and Flutter analysis pass.
- A new macOS debug build was launched from a terminated process with the cached
  `ocaml-sync-test` graph. Without any graph-picker or other UI interaction it
  rendered the dated Timeline; Diagnostics reported `Sync phase = Current`,
  `Startup phase = Ready`, and `Graph phase = Open`.
- No Dune file, OCaml file under `spec/`, cache format, Flutter fallback, or
  bonsai_flutter repository file was changed.

## Questions

- None.
