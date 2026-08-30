# Diagnostics Three-Phase UI

## Problem

The Account dialog currently exposes a **Sync diagnostics** action whose page is
owned and named as if every displayed fact belongs to synchronization. The app
now has three independent lifecycle axes with different canonical owners:

| Axis | Canonical owner | Current values |
| --- | --- | --- |
| Sync | `Logseq_sync_pure_reducer.Core.snapshot.sync_phase` | `Offline`, `Connecting`, `Pulling`, `Submitting`, `Current`, `Paused`, `Failed` |
| Startup | `Journal_startup.derive` in the app UI domain | `Signed_out`, `Loading_catalog`, `Awaiting_selection`, `Restoring_local`, `Bootstrapping`, `Awaiting_e2ee_password`, `Ready`, `Failed` |
| Graph | `Logseq_db_worker.graph_state.phase` | `Graph_closed`, `Graph_opening`, `Graph_open`, `Graph_closing`, `Graph_failed` |

The current diagnostics page receives only
`Logseq_sync_pure_reducer.Core.diagnostics`. Its fallback layout still has a
Manager `Phase` and `Startup presentation` row inherited from the former
sync-owned lifecycle model, while it has no canonical worker graph phase or
app-owned startup phase. This makes the surface incomplete and risks presenting
an internal sync state as the application's overall lifecycle.

The existing Account-dialog entry is also normally reachable only after the
journal is presented. At that point `startup_phase` is usually `Ready`. Keeping
Diagnostics exclusively behind that entry would technically display startup
phase but would not help investigate a startup that is still restoring,
bootstrapping, awaiting an E2EE password, or failed before the journal appears.

This exploration concerns renaming the app surface to **Diagnostics** and adding
the current sync, startup, and graph phases. It does not merge the three axes,
change their state machines, add mutation or retry controls, change sync policy,
or introduce persistent diagnostic storage.

## Proposal

Rename the app feature from **Sync diagnostics** to **Diagnostics**. The rename
should cover visible copy, accessibility labels, commands, modal constructors,
application helpers and fields, and test IDs. Remove the obsolete
`sync-diagnostics` UI route and identifiers instead of retaining aliases or
compatibility handling. The sync library's `diagnostics` type may retain its
name because it still represents sync-owned operational diagnostics rather than
the app page.

Make the top section of the page **Phases** and show exactly three current rows:

| Row | Source | Display value |
| --- | --- | --- |
| Sync phase | the latest sync snapshot in application state | a stable readable name for the `sync_phase` constructor |
| Startup phase | `Journal_startup.derive` from that sync snapshot and the latest worker graph state | a stable readable name for the derived `startup_phase` |
| Graph phase | the latest worker graph state in application state | a stable readable name for the `graph_phase` constructor |

Use owner-qualified labels rather than one unqualified `Phase` row. Keep the
three rows independent: for example, `Sync phase = Connecting`,
`Startup phase = Ready`, and `Graph phase = Open` is valid and must not be
collapsed into a single status. The UI must use exhaustive typed renderers and
must not parse diagnostic strings or infer one phase from another.

Use concise display names without OCaml naming artifacts:

- sync: `Offline`, `Connecting`, `Pulling`, `Submitting`, `Current`, `Paused`,
  and `Failed`;
- startup: `Signed out`, `Loading catalog`, `Awaiting selection`,
  `Restoring local`, `Bootstrapping`, `Awaiting E2EE password`, `Ready`, and
  `Failed`; and
- graph: `Closed`, `Opening`, `Open`, `Closing`, and `Failed`.

The Application is the composition boundary. It already stores the latest sync
snapshot and worker graph state, and it already derives startup state from those
values for startup rendering. Diagnostics should derive and render the same
startup value from the same application state. It must not add a duplicate
startup reducer, copy startup phase into the sync diagnostic projection, or ask
the sync package to infer worker state.

The three values come from independently published owners and therefore are the
latest generation-fenced values observed by the Application, not a new atomic
cross-package snapshot. The page should re-render from existing application
state updates and must not poll either owner. When the sync snapshot is not yet
available, render sync and startup phase as `Not available`; graph phase can
still use the worker's current canonical state. Do not substitute `Offline`,
`Signed out`, or `Closed` for a missing source.

Keep the existing sync-owned operational groups and bounded recent transition
history below **Phases**, subject to these cleanup rules:

- remove the obsolete Manager `Phase` and `Startup presentation` rows so phase
  information has one canonical location on the page;
- retain sync-specific groups such as transport, pull, submission, recovery,
  serialization, authorization, scope fences, graph sync metadata, and the
  sanitized last error;
- keep the existing sync transition history explicitly labeled as sync history;
  do not imply that it records startup or graph transitions; and
- do not add a second history buffer in the Application or worker in this
  change.

The renamed page remains read-only, vertically scrollable at narrow desktop and
phone widths, and limited to at most three dividers. It retains the existing
privacy boundary and has no copy or export action. Opening or closing it must
not issue sync or worker commands, mutate lifecycle state, access the network,
or change Timeline presentation.

Expose the same read-only Diagnostics destination from the startup surface as
well as the Account dialog so the page can diagnose incomplete startup.
The startup entry must remain available in non-`Ready` states, including
`Failed`, and closing it must return to the current startup surface without
resetting or retrying startup.

### Test boundary

Implementation should cover:

- pure renderer tests for every sync, startup, and graph constructor;
- application view tests showing all three rows together, including valid
  non-aligned combinations such as connecting/ready/open and offline/ready/open;
- unavailable-state tests proving missing sync data is not rendered as a real
  phase;
- tests proving the startup row matches `Journal_startup.derive` for the same
  sync snapshot and worker graph state;
- entry, title, close, scroll, semantics, no-copy, and no-export tests using the
  new Diagnostics names and identifiers only;
- reachability tests from the Account dialog and every startup phase, especially
  startup `Failed`;
- source-boundary assertions preventing reintroduction of the old
  `Sync_diagnostics` modal, `sync-diagnostics` commands/test IDs, unqualified
  phase rows, or a compatibility route; and
- the existing diagnostics redaction and maximum-divider coverage.

No OCaml file under `spec/`, Dune file, phase type, sync transport, worker engine
lifecycle, Flutter bridge protocol, or persistent storage format is expected to
change. If implementation reveals that a canonical phase cannot be observed
through the existing public contracts, development must stop and report the
specific specification issue rather than editing `spec/` implementation files.

## Decision

Adopt the proposal in full. The user resolved the remaining product questions
on 2026-08-30:

- expose Diagnostics from incomplete and failed startup states as well as the
  post-startup Account dialog;
- rename user-visible copy and all internal application modal, command, field,
  helper, route, semantics, and test-ID names, deleting the obsolete
  `sync-diagnostics` paths without compatibility aliases; and
- retain the existing bounded transition history as explicitly sync-only, with
  no combined application-owned phase history in this change.

The Diagnostics page therefore composes the latest canonical sync, startup, and
graph phases in the Application while keeping the underlying lifecycle owners
independent. The complete rename and startup reachability are part of the same
cutover rather than optional follow-up work.

## Alternatives considered

### Keep the Sync diagnostics name and add two rows

This is the smallest visible change, but the name would incorrectly place
app-owned startup and worker-owned graph facts under sync ownership. It would
also preserve terminology from the retired aggregate sync phase.

### Build one aggregate diagnostics phase

One value would be easier to scan, but it would recreate the invalid coupling
that the three owner-specific phase types removed. Important states such as an
open, ready graph that is connecting or paused cannot be represented faithfully
by one lifecycle label.

### Copy startup and graph phases into sync diagnostics

This would let the existing page keep one input value, but it would make the
sync reducer publish facts owned by the app and worker. It would also create
duplicate phase projections that can drift from the canonical owners.

### Show phases only after the journal is ready

Keeping only the Account-dialog entry avoids adding startup chrome. It makes
startup phase mostly report `Ready` and prevents the page from diagnosing the
states where startup visibility matters most. This remains viable if the
feature is intended only for post-startup support.

### Add combined startup and graph history now

A unified history could explain ordering across owners, but it requires a new
application-owned event model, bounds, reset policy, redaction review, and
cross-owner ordering semantics. Current phase visibility does not require that
larger observability decision.

## Acceptance criteria

- All user-visible names, semantics, application route names, commands, modal
  names, helpers, fields, and test IDs call the app surface **Diagnostics**;
  obsolete Sync diagnostics UI identifiers and compatibility paths are deleted.
- Diagnostics presents `Sync phase`, `Startup phase`, and `Graph phase` together
  in a visually primary **Phases** section.
- Each phase is rendered exhaustively from its canonical typed owner; the view
  does not parse strings, reconstruct a legacy aggregate phase, or infer one
  owner-specific phase from another.
- The startup value displayed in Diagnostics equals `Journal_startup.derive`
  for the same latest sync snapshot and worker graph state observed by the
  Application.
- Missing sync state renders sync and startup phase as `Not available` while
  preserving the independently available graph phase.
- Valid independent combinations render without coercion, including an open and
  ready graph whose sync phase is offline, connecting, pulling, submitting, or
  paused.
- The obsolete Manager `Phase` and `Startup presentation` rows are removed.
  Existing sync operational diagnostics remain available without claiming to
  contain startup or graph lifecycle history.
- Diagnostics is reachable and dismissible from every non-`Ready` startup state,
  including `Failed`, without triggering recovery or losing startup state.
- The page remains read-only, updates without polling, scrolls at narrow desktop
  and phone widths, and uses no more than three dividers.
- No token, password, cryptographic material, transaction payload, block
  content, snapshot path, signed URL, user ID, or graph catalog data is added to
  rendered output, semantics, history, or screenshots.
- Opening and closing Diagnostics performs no network, sync, graph, retry, or
  Timeline mutation, and no copy or export action exists.
- Focused startup, sync, worker, application view, source-boundary, and full
  repository tests pass, followed by `spec-dev-tool check --all`.

## Consequences

The Application now composes its latest sync snapshot and worker graph state in
one read-only Diagnostics page. Sync, startup, and graph phases retain their
independent canonical owners, while startup display uses `Journal_startup.derive`
from the same two values used by the startup surface.

The Account dialog and every manager-owned startup presentation expose the same
Diagnostics modal. Opening and closing it changes only the application modal,
so incomplete or failed startup remains intact and can continue publishing state
while the page is visible.

All application UI identifiers now use Diagnostics naming. The previous
`Sync_diagnostics`, `sync-diagnostics`, and Sync diagnostics paths are removed,
and the obsolete Manager phase rows are filtered from sync-owned operational
groups. Existing sync transition history remains bounded and explicitly
sync-only; no application history, polling, persistence, copy, or export path is
added.

## Risks

- Three simultaneous phases add terminology to a support screen. Owner-qualified
  labels and a fixed ordering reduce ambiguity, but users still need to
  understand that `Ready` does not mean `Current` and `Offline` does not mean
  the graph is closed.
- The Application can receive sync and worker publications at different times.
  A transient but valid combination may appear between callbacks; Diagnostics
  must describe it as latest observed state rather than promise atomicity.
- A startup-surface entry adds secondary chrome to a sensitive flow and may be
  visible before authentication. The existing redaction boundary must therefore
  hold even when no account or graph is selected.
- Renaming internal application identifiers makes the change intentionally
  breaking for tests and automation. This is preferable to maintaining parallel
  old and new routes under the repository's no-compatibility policy.
- Retaining sync-only transition history beneath three current phases may be
  misread as complete lifecycle history. Its heading and explanatory copy must
  identify its sync-only scope.

## Questions

None. The user resolved startup reachability, complete internal and external
renaming, and sync-only transition-history scope on 2026-08-30.
