# Diagnostics Overlay DB Information

## Problem

The Diagnostics page currently combines three current lifecycle phases, legacy
sync-owned diagnostic groups, and a **Recent sync transitions** section. The
transition section is backed by a bounded list of 32 sanitized strings in
`Logseq_sync_pure_reducer.Core.diagnostics.history`. It describes sync reducer
events rather than the logical database that the user is currently reading and
editing, so it occupies the most detailed part of the page without exposing the
state needed to diagnose Overlay DB projection or outbox problems.

Overlay DB is the canonical owner of the coherent logical graph assembled from
the authoritative mirror and pending local intent. Its public API already
exposes two relevant typed observations:

| Observation | Existing source | Available facts |
| --- | --- | --- |
| Graph and projection | `Database.graph_info` on a captured snapshot | graph identity and name, schema, admission facts, capability limits, generation, and projection revision |
| Outbox admission | `Database.inspect_admission` on the open database | active records and bytes, protected wire bytes, retained origin-evidence bytes, and maximum records and bytes |

The Worker already maps `Database.graph_info` into `Protocol.V2_graph_info_outcome`.
`Journal_graph_runtime` reads that outcome when a graph opens and during
rehydration, but `Application.apply_worker_response` currently discards all of
its fields after marking the graph ready. `Database.inspect_admission` has no
production consumer and does not cross the Worker protocol.

The requested page update is therefore not only a layout change. It requires a
typed path from the Worker-owned database to Application presentation. The user
confirmed on 2026-09-04 that removing Recent sync transitions also retires the
sync history data model and producer as obsolete, rather than being a
presentation-only change. The user selected the four current outbox-admission
measurements returned by `Database.inspect_admission` as the complete Overlay DB
field set and selected Worker-event-driven refresh as their freshness contract.
Graph-info, identity, schema, version, and admission-fact fields are not part of
this page.

This exploration covers the read-only Diagnostics surface and the minimum typed
data path required to support it. It does not change Overlay DB persistence,
projection semantics, sync policy, mutation admission rules, retry behavior, or
provide controls that alter database state.

## Proposal

Remove the **Recent sync transitions** section from the Diagnostics page. Do not
replace it with another event log or expose raw reducer, Worker, storage, or
Datascript events. In the same cutover, remove `diagnostics.history`,
`append_diagnostic_history`, all history-producing reducer paths, the Bonsai
service mapping, UI helpers, and tests whose only purpose is the retired history.
Do not retain empty fields, fallback rows, compatibility adapters, or aliases for
the deleted model.

Add one **Overlay DB** section after **Phases** with exactly these four compact
rows:

| Row | Canonical source | Example rendering |
| --- | --- | --- |
| Outbox records | `active_records`, `maximum_records` | `12 / 4096` |
| Outbox bytes | `active_bytes`, `maximum_bytes` | `128 KB / 8 MB` |
| Protected payload | `protected_wire_bytes` | `96 KB` |
| Origin evidence | `retained_origin_evidence_bytes` | `240 B` |

Do not add status, graph UUID, graph name, schema, admission facts, capability
limits other than the two paired outbox maxima, generation, projection revision,
filesystem paths, block or transaction content, mutation IDs, checksums, or
encrypted or plaintext values. The section is a compact admission view, not a
general Overlay DB metadata dump.

Keep Overlay DB as the canonical data owner and Worker as the serialization and
publication boundary. The App must not hold a `Logseq_overlay_db.Database.t`,
open storage, or call Overlay DB directly. Prefer one typed Worker-owned
observation obtained from `inspect_admission` on the current open database. Do
not encode the new facts as diagnostic strings or append them to sync-owned
`diagnostic_group` values.

The section must define an explicit unavailable state for a graph that is
closed, opening, closing, failed, replaced by a newer generation, or unavailable
while Diagnostics is reachable during startup. Values from a previous graph or
generation must be cleared rather than displayed as current. A read failure may
show a concise sanitized availability error, but it must not surface internal
paths, exception text, data content, or crypto material.

Use event-driven pull rather than polling or a dedicated admission-change push.
Capture one fresh inspection when Diagnostics opens against an already-open
graph. While the page remains open, request another inspection after an existing
current-generation Worker event that can follow Overlay DB work, including graph
open, logical projection publication, successful local mutation completion, and
sync database-effect completion. Coalesce events while an inspection is already
in flight, then perform at most one follow-up inspection if another relevant
event arrived. Closing Diagnostics stops refresh requests. Fence every request
and response by graph generation so a late result cannot repopulate a closed or
replaced graph.

This contract provides a fresh observation at known Worker boundaries without
claiming a push for every internal outbox transition. The page may briefly show
the previous current-generation observation between a Worker event and its
follow-up response; it must not describe the values as an atomic event log.

The page remains read-only and vertically scrollable, uses the existing
Diagnostics modal and entry points, and complies with the maximum of three
dividers in `docs/ux-guidelines.md`. Opening, refreshing, or closing Diagnostics
must not change graph, sync, startup, outbox, or Timeline state.

Implementation may require exposing admission inspection through a public Worker
`.mli`. Any implementation request must explicitly include that specification
change if the selected data path crosses the boundary; development must not edit
an OCaml file under `spec/` merely to bypass the public contract.

## Decision

Adopt the proposal in full. The user resolved the product questions on
2026-09-04:

- delete Recent sync transitions and every history field, producer, mapping,
  fallback, and history-only test rather than hiding the section only;
- show exactly the four compact `Database.inspect_admission` rows specified
  above and no graph-info or identifying metadata; and
- capture admission data when Diagnostics opens and refresh it after relevant
  existing Worker events while the page is open, with coalescing and generation
  fencing, but without polling or a dedicated per-transition push.

## Alternatives considered

### Reuse only the existing graph-info response

Store the latest `V2_graph_info_outcome` in Application state and render its
schema, generation, projection revision, admission facts, and limits. This is the
smallest data-path change and requires no new Overlay DB read, but it cannot show
current outbox occupancy. The selected UI requires current and maximum record and
byte measurements from `inspect_admission`, so graph-info alone does not satisfy
the requested field set.

### Add Overlay DB facts to sync diagnostics

Extend `Logseq_sync_pure_reducer.Core.diagnostic_group` with an Overlay DB group.
This preserves the current page input shape, but it makes Sync publish state
owned by Overlay DB and requires stringly typed duplication across package
boundaries. It also cannot guarantee that the strings correspond to the current
open Worker database generation.

### Let the App query Overlay DB directly

Give Application access to the database and call `graph_info` and
`inspect_admission` when the page opens. This avoids a Worker protocol addition,
but violates the existing ownership boundary: Worker owns database lifetime and
serialized access, while the App owns presentation only.

### Show a raw diagnostic dump

Render all graph-info fields, admission facts, internal errors, and recent events
as a developer-oriented text block. This is easy to extend but creates an
unstable UI contract, weak accessibility, poor scanning, and unnecessary privacy
and redaction risk. Typed labeled rows give each exposed fact an explicit product
decision.

### Replace transition history with an Overlay DB event history

Record projection and outbox transitions instead of current facts. Event history
could explain ordering failures, but it requires a new bounded event model,
redaction policy, reset semantics, and ordering guarantees. The requested change
can be satisfied with current state and occupancy, so a new history is outside
this exploration.

## Acceptance criteria

- Diagnostics contains no **Recent sync transitions** heading or transition rows.
- The sync diagnostics model contains no history field or producer. Service and
  Application mappings, fallback copy, source-boundary expectations, and
  history-only tests are removed rather than retained as dormant compatibility
  paths.
- Diagnostics contains a distinct **Overlay DB** section with exactly
  `Outbox records`, `Outbox bytes`, `Protected payload`, and `Origin evidence`,
  sourced from the corresponding typed `Database.inspect_admission` fields.
- Overlay DB values are obtained through the Worker-owned database boundary; the
  App never opens storage or receives a database handle.
- Every displayed observation belongs to the current open graph generation.
  Closing, replacing, or failing the graph clears stale values and renders an
  explicit unavailable state.
- The freshness behavior is deterministic, documented, and tested. The page does
  not poll in the background or subscribe to a dedicated admission-change push.
- Opening Diagnostics with an open graph requests one current inspection.
  Relevant current-generation Worker events request a refresh while the page is
  open, concurrent triggers are coalesced, and closing the page stops refresh
  requests.
- Missing observations and read failures use concise sanitized UI states without
  exposing raw exception messages or sensitive graph, mutation, transaction,
  filesystem, sync, or cryptographic data.
- Byte counts use one tested compact formatter that produces units such as `B`,
  `KB`, and `MB`, remains unambiguous about bytes versus records, and handles
  zero, non-round values, and configured maxima.
- The page remains read-only, reachable from the existing Account and startup
  entries, dismissible without state changes, vertically scrollable at supported
  widths, and uses no more than three dividers.
- Focused Overlay DB, Worker, service, Application view, redaction, generation
  fence, source-boundary, and full repository tests pass, followed by
  `spec-dev-tool check --all`.
- No OCaml file under `spec/` or Dune file is changed without the explicit scope
  required by repository policy.

## Risks

- `inspect_admission` observes the live open database rather than a captured
  snapshot. The Worker must fence its result to the current graph generation so
  a late response cannot populate the page after graph replacement or closure.
- Live outbox counts can change because of local commits, transport-only
  transitions, authoritative acknowledgement, or recovery. Existing logical
  projection pushes do not necessarily cover every such change, so reusing only
  projection invalidation can leave admission data stale.
- Outbox byte categories overlap conceptually for readers. Showing too many
  counters can imply that their sum equals total durable storage when it does
  not. The selected four-row layout must not visually suggest that `Protected
  payload` and `Origin evidence` are additive components of `Outbox bytes`.
- Removing sync history from the data model reduces evidence currently used by
  managed-sync end-to-end tests and runtime diagnostics. Tests must assert the
  underlying typed outcomes or current state instead of replacing the deleted
  history with another string event log.
- Expanding the Worker protocol for one screen increases public contract surface.
  Reusing graph-info alone avoids that cost but gives an incomplete admission
  picture.

## Consequences

Diagnostics becomes a compact current-state surface rather than a string event
log. Sync no longer stores or exposes recent transition history, and tests that
used those strings must assert typed state and outcomes instead.

Application owns only the optional presentation observation and its current
graph-generation fence. Worker retains database ownership, performs
`inspect_admission`, and returns typed counts through the selected request path.
The App requests an initial value on open and refreshes after relevant existing
Worker events, so the feature adds bounded event-driven reads but no timer and no
new stream of internal outbox transitions.

## Questions

None. The user confirmed the displayed fields, complete history removal, privacy
boundary, and Worker-event-driven refresh behavior on 2026-09-04.
