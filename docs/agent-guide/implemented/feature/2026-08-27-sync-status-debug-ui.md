# Sync Status Debug UI

## Problem

The application exposes sync failures only through user-facing loading, offline,
and error messages. Those messages are intentionally compact, but they do not
show enough state to distinguish common support cases such as:

- a graph that is open locally but waiting for its opening WebSocket pull;
- a live connection with a pull already in flight;
- a disconnected connection waiting for reconnect backoff;
- a local transaction that is deferred or awaiting authoritative replay;
- a startup that has not crossed the Timeline presentation barrier; and
- a stale callback that was rejected by an account, graph, presentation, or
  connection generation fence.

The application already retains a `Logseq_sync.Manager.snapshot` containing the
public phase, startup-presentation phase, account/graph/presentation/connection
generations, selected graph, applied server transaction, and last error. The
manager also owns operational state that is not exposed in that snapshot:
WebSocket lifecycle, reconnect attempt, pull coalescing, frame application,
submission lifecycle, pending token challenges, and uncertain-submission
recovery. Its existing `Manager.diagnostics` function emits only the numeric
manager phase, generations, and token-challenge count as one string, and it is
not presented in the app UI.

As a result, diagnosing a sync report currently requires attaching a debugger,
adding temporary logging, or reproducing the issue in a test. This is especially
costly for intermittent lifecycle and reconnect failures on a user's device.

This exploration concerns read-only sync diagnostics and a bounded in-memory
history in the `logseq_journal` app UI. It does not add manual sync controls,
retry buttons, mutation controls, remote server inspection, persistent logging,
or changes to sync policy.

## Proposal

Add a read-only **Sync diagnostics** action to the existing Account dialog in all
build modes. The action opens a dedicated modal page rather than placing the data
directly in the current Settings dialog: the Settings dialog is
presentation-oriented and already contains a typography chooser and metrics,
while sync diagnostics need a scrollable, monospaced or label/value layout that
can grow without overflowing a compact alert dialog.

The user selected the Account-dialog entry and all-build availability on
2026-08-27. The destination remains secondary support UI rather than permanent
Timeline chrome.

The surface should show one coherent snapshot captured from the same serialized
manager owner that performs sync transitions. It must not assemble values by
independently querying the database, WebSocket host, and UI state, because those
reads could describe different transition moments. The UI may re-render whenever
the existing manager-state push changes; it does not need polling.

### Diagnostic contract

Expose structured, display-safe values rather than making the UI parse
`Manager.diagnostics`. The minimum useful snapshot is:

| Group | Fields |
| --- | --- |
| Manager | named `phase`, named `startup_presentation`, `last_error` |
| Scope fences | account, graph, presentation, and connection generations |
| Graph | whether a graph is selected and `applied_server_t` |
| Transport | foreground or suspended; disconnected, awaiting token, connecting, live, revalidating, or backing off; initialized flag where applicable |
| Pull | idle or in flight; whether another pull is requested |
| Submission | none, deferred, or in flight; transaction count only |
| Recovery | reconnect attempt and uncertain transaction count |
| Serialization | idle, applying pull, applying transaction, or applying control |
| Authorization | pending ID-token challenge count |

The recommended contract is the complete structured operational snapshot above,
not only the existing `Manager.snapshot`. The existing snapshot cannot identify
whether a stall belongs to WebSocket readiness, pull ownership, submission,
reconnect recovery, or serialized frame application. A typed diagnostic
projection supplies that information without exposing the manager's private
constructors directly to the view.

The contract should use named variants and typed fields. Numeric enum encodings
are not readable enough for the UI and a free-form string would make tests depend
on formatting. The existing product-facing `Manager.snapshot` can remain focused
on application behavior; a separate diagnostic record should be attached to the
same service-owned state notification so the current snapshot and history update
atomically.

The UI should render unavailable values explicitly as `None` or `Not available`,
not as zero. It should show the full selected graph UUID in the current snapshot.
Long errors should wrap. State names should be exact engineering terms rather
than translated user-facing summaries so screenshots can be matched to manager
transitions and tests. The page should remain readable at narrow macOS window
widths and iPhone widths, use at most three dividers as required by the repository
UI rules, and allow vertical scrolling. The first version has no copy or export
action.

### Bounded transition history

Include a deliberately small recent history below the current snapshot. Record a
history entry only when one or more of these display-safe projections changes:

- manager phase or startup-presentation phase;
- account, graph, presentation, or connection generation;
- transport or suspension state and WebSocket initialization;
- pull, submission, or serialized frame-application state;
- reconnect attempt or uncertain-transaction count;
- applied server transaction; or
- whether `last_error` is present.

Each entry contains a process-local sequence number, a concise change category,
and display-safe before/after state names or numeric values. Error transitions
record `set`, `changed`, or `cleared`, not a second copy of the error text.
Consecutive identical projections are coalesced. Keep at most 64 entries in a
ring buffer, evicting the oldest entry when the 65th is appended. Store the
history only in memory: do not write it to SQLite, preferences, files, platform
logs, crash metadata, or analytics.

The history resets on process start, sign-out, or authenticated-account
replacement so a later account cannot inspect the prior account's activity. A
graph switch may remain visible as a scope change, but history entries never
contain current or previous graph UUIDs; the full UUID appears only in the
current snapshot. Render entries in chronological order and keep the current
snapshot visually primary.

### Privacy and security boundary

Diagnostics must never expose credentials or sync payload content. In
particular, omit:

- ID tokens, token challenge values, cookies, and authorization headers;
- E2EE passwords, private keys, graph keys, wrapped keys, IVs, and ciphertext;
- transaction payloads, transaction bodies, block content, snapshot paths, and
  signed artifact URLs;
- the authenticated user ID, managed-sync origin query values, and the graph
  catalog; and
- raw internal exception objects or backtraces that may contain any omitted
  value.

Counts, state names, generation numbers, the applied server transaction, a
sanitized existing `last_error`, and the current selected graph UUID are
sufficient for the first version. The UUID is intentionally visible, but it is
not repeated in history and there is no copy/export action.

### Test boundary

If this exploration becomes proposed, implementation should cover:

- manager-level tests that fail before the structured diagnostic snapshot
  reports transport, pull, submission, recovery, and fence transitions;
- service tests proving each UI snapshot comes from the serialized manager owner
  and contains no payload or secret material;
- application view tests for entry, dismissal, scrolling, labels, unavailable
  values, the current graph UUID, long errors, live updates, and absence of copy
  controls;
- deterministic history tests for key-change filtering, duplicate coalescing,
  ordering, 64-entry eviction, account-boundary reset, process-only lifetime, and
  omission of UUIDs and error text;
- source-boundary assertions that prevent the view from parsing the legacy
  diagnostic string or directly depending on private manager constructors; and
- Flutter runtime or golden coverage only if the selected layout or build-mode
  visibility cannot be established by the OCaml application tests.

No OCaml file under `spec/`, Dune file, Flutter bridge protocol, sync transport,
or persistent storage format is expected to change unless the selected answers
make one of those boundaries necessary. Implementation must remove any obsolete
diagnostic path it replaces rather than retaining parallel compatibility output.

## Decision

Adopt the proposal in full. The user confirmed the complete structured
operational snapshot on 2026-08-27. Sync diagnostics therefore exposes the
manager, fence, graph, transport, pull, submission, recovery, serialization, and
authorization groups defined above rather than limiting the UI to the existing
`Manager.snapshot` fields.

The Account dialog owns the entry in all builds. The current snapshot shows the
full selected graph UUID and provides no copy/export action. A process-local ring
retains at most 64 key projected transitions, excludes graph UUIDs and repeated
error text, and resets at the selected account boundaries.

## Alternatives considered

### Add the fields directly to Settings

This reuses an existing destination, but it mixes support information with user
presentation preferences and risks making the current alert dialog too tall.
A dedicated page gives the diagnostic data a scroll boundary and independent
navigation while remaining reachable from the account UI.

### Show a persistent sync badge on the Timeline

A badge makes coarse health visible without navigation, but it adds permanent
chrome to the primary reading surface and cannot show the state needed for
diagnosis. A future user-facing sync indicator can consume a deliberately small
product status; it should not expose the engineering snapshot proposed here.

### Show only the existing `Manager.snapshot`

This is the smallest implementation and already exposes the public phase,
generations, cursor, and error. It cannot distinguish the transport, pull,
submission, reconnect, and serialization states responsible for most sync-loop
diagnosis, so it may not satisfy the support goal.

### Render `Manager.diagnostics` as text

This avoids a new type but preserves numeric phase encoding, omits most relevant
state, and couples UI tests to a log string. Extending the string would also make
redaction and field-level presentation harder to enforce than a typed record.

### Add persistent or unbounded event history

Longer retention could diagnose failures that predate the current process, but it
would introduce a storage format, cleanup policy, cross-account exposure risk,
and a larger redaction surface. A 64-entry process-local ring records recent key
transitions without creating durable diagnostic data.

### Rely on console logging

Logs are useful for automated collection but are difficult to access on a user's
device and can accidentally persist sensitive values. They do not satisfy the
request for UI-visible debug information.

## Acceptance criteria

- The Account dialog exposes a discoverable, read-only Sync diagnostics action in
  debug, profile, and release builds.
- The destination shows one coherent manager-owned sync snapshot and updates
  without polling when relevant manager state changes.
- Every displayed state uses a stable descriptive name; absent values are not
  confused with zero or an idle state.
- The selected diagnostic depth is sufficient to distinguish startup phase,
  generation fences, durable server cursor, transport readiness, pull ownership,
  pending submission, serialization, and reconnect recovery.
- No token, password, cryptographic material, transaction payload, block content,
  snapshot path, signed URL, user ID, or catalog data appears in the snapshot,
  history, rendered semantics, or screenshots. The current snapshot may show the
  full selected graph UUID.
- The UI exposes no copy or export action.
- The history contains only key projected state changes, coalesces duplicates,
  retains at most 64 chronological entries, evicts the oldest entry first, and
  never contains a graph UUID or error text.
- History is process-local and resets on sign-out or account replacement; no
  diagnostic history is written to persistent storage, logs, crash metadata, or
  analytics.
- The page scrolls at narrow desktop and phone widths, long errors wrap, and the
  complete UI uses no more than three dividers.
- Opening and closing diagnostics does not issue a sync command, request network
  access, mutate manager state, or change Timeline presentation.
- Automated tests cover representative connected, pulling, backing-off, deferred-
  submission, paused, unavailable, and long-error snapshots.

## Risks

- Exposing private manager concepts creates a maintenance obligation when the
  sync state machine changes. A typed diagnostic projection should intentionally
  translate internal constructors instead of making the UI depend on them.
- A 64-entry key-transition history can still miss older failures or repeated
  events that do not change projected state. That is an intentional bound, not a
  durable observability system.
- Release-build availability helps support real devices but exposes implementation
  detail to every user who finds the entry.
- Omitting copy/export requires a screenshot or manual transcription for bug
  reports, but avoids a second redaction surface in the first version.
- The full current graph UUID can correlate a screenshot with a remote graph. It
  is deliberately retained for diagnosis but never copied into the transition
  history.

## Consequences

The sync manager now owns a typed diagnostic projection and bounded transition
history alongside its product snapshot. The serialized worker owner publishes
both values atomically, so the application can update the diagnostics page from
the existing manager-state push without polling or cross-owner reads.

The Account dialog gains an all-build, read-only route whose scrollable content
exposes the selected graph UUID only in the current snapshot. History remains
process-local, contains only display-safe state changes, and resets at account
boundaries. The UI deliberately has no copy, export, retry, or mutation action.

Future sync-state changes must update the typed projection, stable display names,
history filtering, and their tests together. This maintenance cost is accepted
in exchange for device-visible support diagnostics with an explicit privacy
boundary.

## Questions

None. The user resolved these questions on 2026-08-27:

- open a dedicated Sync diagnostics action from the Account dialog;
- make the surface available in all builds;
- expose the complete structured operational snapshot;
- provide no copy action and show the full current graph UUID; and
- include at most 64 key state changes in memory without persistence.
