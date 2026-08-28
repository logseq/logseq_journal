# Split Sync Graph Startup Phases By Owner

## Problem

`Logseq_sync.Api.phase` currently combines account and presentation startup,
database-engine lifecycle, and synchronization activity in one sum type:

```ocaml
type phase =
  | Signed_out
  | Loading_catalog
  | Awaiting_selection
  | Restoring_local
  | Bootstrapping
  | Awaiting_e2ee_password
  | Opening_graph
  | Graph_open
  | Sync_paused
  | Failed
```

These values do not describe one state axis. `Opening_graph` and `Graph_open`
describe the worker-owned `Engine` and storage session. `Restoring_local` and the
Timeline presentation barrier describe application startup. `Sync_paused`
describes synchronization policy. `Failed` can mean a failure in any of those
owners. A consumer therefore cannot interpret the phase without also knowing
which subsystem produced it.

The mixed type has already moved ownership into the wrong public surface:

- `logseq_sync/spec/api.mli` exposes local engine availability as sync state;
- `app/application.ml` renders account, bootstrap, engine-open, and offline-sync
  UI by exhaustively matching the same `Logseq_sync.Api.phase`;
- `Logseq_sync.Api.public_phase` collapses internal stopping, token, graph, and
  presentation states into the same public values; and
- a `Graph_open` value says nothing about whether the WebSocket is connected,
  a pull is active, pending transactions are being submitted, or the graph is
  current with the server.

This also weakens the package boundary established by the sync dependency
injection work. The intended responsibility split is:

```text
logseq_sync
  - synchronization protocol and convergence state

logseq_db_worker
  - graph Engine and database-session lifecycle

app UI domain
  - account-to-first-frame startup presentation
```

In this decision, `ui_domain` means the existing unwrapped `app` library defined
by `app/dune`. It does not mean a new top-level directory, library, or package.
The startup type belongs to an app-owned domain module and remains unavailable
to the lower sync and worker packages.

## Proposal

Replace the single public `phase` with three independent types, each declared by
the package that owns the facts represented by the type. Delete the old
`Logseq_sync.Api.phase`; do not retain aliases, compatibility constructors, or a
derived legacy phase.

### Keep only synchronization phase in `logseq_sync`

Declare the public synchronization state in `logseq_sync/spec/api.mli`:

```ocaml
type sync_phase =
  | Offline
  | Connecting
  | Pulling
  | Submitting
  | Current
  | Paused
  | Failed
```

`Logseq_sync.Api.snapshot` exposes `sync_phase` instead of the mixed `phase`.
The variants have these meanings:

| Variant | Meaning |
| --- | --- |
| `Offline` | No active online reconciliation is available. Local projected data may still be usable. |
| `Connecting` | The client is acquiring online authority or establishing/revalidating its sync transport. |
| `Pulling` | An authoritative pull is requested or being applied. |
| `Submitting` | A local pending batch is deferred for immediate transport or is in flight. |
| `Current` | The authoritative cursor is current and there is no active pull or submission. |
| `Paused` | Sync policy intentionally stopped network convergence after a recoverable integrity or submission problem. |
| `Failed` | The sync client cannot continue synchronization without reconstruction or external intervention. |

Catalog values, graph selection, token challenges, bootstrap progress, and E2EE
commands may remain API operations because the managed-sync client owns their
protocol and policy. They no longer become fake synchronization phases. The
public sync phase must report synchronization activity only.

Private sync implementation state may remain more detailed. In particular,
generation fences, token purposes, pending-entry states, E2EE session states,
and the type-enforced Timeline presentation permit are not public product
phases. If an internal module named `Startup_phase` remains necessary to enforce
network authority, it must be treated as a private capability implementation,
not as the owner of the UI `startup_phase` below.

### Put graph lifecycle phase in `logseq_db_worker`

Declare the database-engine lifecycle in the worker-owned public surface:

```ocaml
type graph_phase =
  | Graph_closed
  | Graph_opening
  | Graph_open
  | Graph_closing
  | Graph_failed
```

The worker is the sole authority for these transitions because it owns graph
ownership, `Storage_session`, the projected and authoritative databases, and
`Engine.close`. The `graph_backend.open_graph` and `close_graph` callbacks must
update this state at the same serialized composition boundary that opens or
closes the engine.

`logseq_sync` may retain an opaque optional backend handle needed to call the
injected graph backend. It must not publish or independently derive
`graph_phase`. A successful `open_graph` callback is worker evidence for
`Graph_open`; a sync transport state is not.

The worker must publish current graph phase through one canonical worker-owned
state or push contract. The Application must stop inferring graph readiness from
`selected_graph`, `applied_server_t`, or `Logseq_sync.Api.Graph_open`.

### Put startup presentation phase in the existing `app` UI domain

Create a UI-domain-owned startup model:

```ocaml
type startup_phase =
  | Signed_out
  | Loading_catalog
  | Awaiting_selection
  | Restoring_local
  | Bootstrapping
  | Awaiting_e2ee_password
  | Ready
  | Failed
```

`startup_phase` describes what prevents the Application from presenting the
journal, not what either backend is doing internally. An app-owned domain
reducer in the existing `app` library reduces application authentication state,
sync events, bootstrap progress, graph phase, and Timeline presentation
acknowledgement into this type.

`Ready` requires both a worker-owned `Graph_open` fact and completion of the
current-generation Timeline presentation contract. It does not require
`sync_phase = Current`; an offline or paused graph remains usable after local
presentation. `Failed` is limited to failures that prevent startup or local
journal presentation. A runtime sync failure after `Ready` remains a sync status
and must not send the UI back through startup.

`Failed` remains payload-free. The app UI domain exposes failure detail and
recovery separately through a structured value. The intended shape is:

```ocaml
type startup_error_owner =
  | Authentication
  | Catalog
  | Local_restore
  | Bootstrap
  | E2ee
  | Graph

type startup_recovery =
  | Sign_in
  | Refresh_catalog
  | Begin_online_recovery
  | Submit_e2ee_password
  | Retry_graph_open

type startup_error =
  { owner : startup_error_owner
  ; message : string
  ; recovery : startup_recovery option
  }

type startup_state =
  { phase : startup_phase
  ; error : startup_error option
  }
```

The recovery value is declarative UI-domain data, not a callback. Application
event handling remains responsible for translating it into the appropriate auth,
sync, or worker command. Keeping it separate allows the phase to stay suitable
for exhaustive layout selection without discarding actionable error context.

The target dependency and observation flow is:

```text
Logseq_sync.Api.sync_phase -----------+
                                      |
Logseq_db_worker.graph_phase ---------+--> app startup_phase --> Application UI
                                      |
Authentication and presentation -----+
```

The existing `app` library may depend on the public sync and worker value types,
as it already does. Neither `logseq_sync` nor `logseq_db_worker` may depend on
the `app` library or its startup types.

### Derive each axis independently

There is no one-to-one conversion from the old phase to the new types. The
Application observes all three axes concurrently. Representative states are:

| Scenario | `sync_phase` | `graph_phase` | `startup_phase` |
| --- | --- | --- | --- |
| Signed out | `Offline` | `Graph_closed` | `Signed_out` |
| Catalog request | `Connecting` | `Graph_closed` | `Loading_catalog` |
| Cached mirror opening offline | `Offline` | `Graph_opening` | `Restoring_local` |
| Snapshot download | `Connecting` | `Graph_closed` | `Bootstrapping` |
| Local graph open before first frame | `Offline` or `Connecting` | `Graph_open` | `Restoring_local` |
| Journal visible while WebSocket connects | `Connecting` | `Graph_open` | `Ready` |
| Pending Capture submission | `Submitting` | `Graph_open` | `Ready` |
| Authoritative pull | `Pulling` | `Graph_open` | `Ready` |
| Checksum pause with usable local graph | `Paused` | `Graph_open` | `Ready` |
| Engine open failure | `Offline` | `Graph_failed` | `Failed` |

State publication must preserve generation fencing. A graph phase from an old
graph generation or a startup acknowledgement from an old presentation
generation cannot change the current UI-domain startup phase.

### Scope of the eventual cutover

The implementation should be an all-at-once public state cutover:

1. Define `sync_phase` in the canonical sync specification and remove the old
   mixed phase from the sync API and implementation.
2. Add the worker-owned graph lifecycle type and publish its transitions from
   the engine composition boundary.
3. Add an app-owned startup domain module to the existing `app` library and move
   startup presentation derivation and copy selection out of
   `app/application.ml` into its reducer.
4. Update the Application to observe all three states without reconstructing
   one legacy aggregate phase.
5. Replace tests that assert the mixed phase with owner-specific transition and
   cross-layer composition tests.
6. Delete obsolete phase renderers, aliases, fallback mappings, and compatibility
   paths.

## Decision

- Replace the public `Logseq_sync.Api.phase` with `sync_phase` and derive it
  exclusively from synchronization transport, pull, submission, pause, and
  terminal-failure facts.
- Publish protocol startup facts separately from `sync_phase`; these facts are
  reducer inputs and are not another aggregate lifecycle phase.
- Make `Logseq_db_worker` the canonical owner of generation-fenced
  `graph_phase` and `graph_state`. Publish state at the serialized engine open,
  close, graph-switch, failure, and shutdown boundary.
- Make `Journal_startup` in the existing `app` library the canonical owner of
  `startup_phase`, structured startup errors, and declarative recovery values.
- Require `Ready` to observe both the current worker generation in
  `Graph_open` and completion of Timeline presentation. Do not require any
  particular `sync_phase` for a locally usable graph.
- Start Application graph requests from worker graph-state evidence. Do not
  infer engine readiness from sync selection or authoritative cursor fields.
- Delete the old public phase, renderer, conversion, constructors, and all
  compatibility paths in one cutover.

## Alternatives considered

### Keep one phase in `logseq_sync`

This preserves the smallest API and the current exhaustive Application match.
It leaves graph readiness and UI startup owned by the sync package, keeps
`Graph_open` ambiguous, and makes future sync activity variants compete with
unrelated presentation states.

### Move the entire managed lifecycle to `logseq_db_worker`

The worker could own catalog, bootstrap, E2EE, transport, graph open, and UI
startup as one serialized service. This restores a single owner but reverses the
package extraction: worker code would again own sync protocol policy and host
effects that now belong behind `Logseq_sync.Api`.

### Keep one aggregate phase in the app UI domain

The UI domain could define a single combined sum type derived from sync and
worker states. This is acceptable as a private rendering decision for one
screen, but it must not become another canonical lifecycle contract. A single
aggregate public type recreates the invalid state coupling and forces every UI
consumer to discard information from the other two axes.

### Put all three types in `logseq_db_types`

This would make the types easy to share without dependency cycles, but
`logseq_db_types` should own storage-neutral values shared by lower packages,
not application presentation or operational lifecycle policy. Putting phases
there would erase ownership instead of clarifying it.

## Acceptance criteria

- `logseq_sync` publicly declares only `sync_phase`; its public API contains no
  graph lifecycle or UI startup phase constructors.
- `Logseq_sync.Api.snapshot` reports `sync_phase` independently of catalog,
  graph-open, and Timeline-presentation state.
- `logseq_db_worker` owns and publishes the canonical `graph_phase`, with tested
  transitions for open success, open failure, close, graph switch, and shutdown.
- The existing `app` library owns the canonical `startup_phase`, structured
  `startup_error`, and declarative recovery value, deriving them from current,
  generation-fenced authentication, sync, graph, bootstrap, E2EE, and
  presentation inputs.
- An open local graph can reach `startup_phase = Ready` while
  `sync_phase = Offline`, `Connecting`, `Submitting`, `Pulling`, or `Paused`.
- `sync_phase = Current` cannot by itself imply `graph_phase = Graph_open` or
  `startup_phase = Ready`.
- `app/application.ml` no longer pattern matches a sync-owned phase to render
  signed-out, graph-opening, bootstrap, or E2EE startup UI.
- The old `Logseq_sync.Api.phase` and its constructors are deleted without a
  compatibility alias, fallback conversion, or migration layer.
- Focused sync, worker, UI-domain, application integration, source-boundary, and
  full repository tests pass.
- `spec-dev-tool check --all` succeeds after the implementation decision is
  completed.

## Consequences

- Sync diagnostics can distinguish offline, connection, pull, submission,
  current, paused, and terminal synchronization states without implying graph
  or UI readiness.
- Worker clients can query the current graph lifecycle and subscribe to
  generation-fenced graph-state changes. Stale open or failure completions
  cannot overwrite a newer graph generation.
- Startup rendering and recovery copy are independently testable without
  Bonsai or worker execution, while Application event handling remains the
  exhaustive translator from declarative recovery values to commands.
- An offline, connecting, pulling, submitting, or paused graph can remain
  usable after the current Timeline frame is presented.
- The public cutover is intentionally breaking. Consumers must use all three
  owner-specific axes; no legacy aggregate phase or fallback mapping remains.

## Risks

- Three independent event streams can be observed at slightly different times.
  The UI-domain reducer must serialize them and reject stale generations rather
  than assuming cross-package callbacks are atomically delivered.
- The names `Offline`, `Failed`, and `Ready` are intentionally concise but can be
  overinterpreted. Their invariants must be documented and tested, especially
  that offline does not mean graph unavailable and ready does not mean synced.
- Moving startup presentation ownership must not remove the sync client's
  private capability gate that prevents online work before the current Timeline
  frame is presented.
- Publishing worker graph lifecycle introduces a new observable contract. It
  must describe the managed graph engine rather than individual request
  execution or WebSocket state.
- Adding the reducer to the existing unwrapped `app` library increases that
  library's domain responsibility. The new module must remain UI-framework-free
  and independently testable so phase derivation does not stay embedded in the
  Bonsai `Application` component.
- A structured recovery enum can drift from the commands supported by auth,
  sync, and worker adapters. Composition tests must cover every recovery variant
  and keep translation exhaustive.

## Questions

- None. `ui_domain` refers to the existing `app` library defined by `app/dune`,
  and `startup_phase = Failed` remains payload-free with separate structured
  error and recovery values.
