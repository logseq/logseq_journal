# Worker Owned Managed Sync Orchestration

## Problem

`logseq_db_worker` and `logseq_sync` are separate packages but currently run
inside the same dedicated Bonsai Flutter Worker Domain. The managed worker
service creates the sync client, injects a graph backend, and then lets the sync
client drive graph lifecycle and database activity through that backend.

The callback surface includes graph open and close, checkpoint reads,
authoritative and projected database reads, local mutation preparation,
projection reset and replay, authoritative staging, and checkpoint persistence.
This means the package that owns the synchronization protocol also decides when
the database engine is opened, closed, queried, and mutated. The worker owns the
`Engine.t` value and publishes `graph_phase`, but the sync client remains the
effective managed-session orchestrator.

That direction is opposite to the desired runtime model:

```text
logseq_db_worker
  - owns the managed session and serialized event loop
  - owns Engine, Storage_session, graph lifecycle, and database commits
  - owns all orchestration outside synchronization protocol and convergence

logseq_sync
  - owns remote protocol, transport, authentication challenges, encryption,
    checksums, pull/submission policy, and sync_phase
  - advances synchronization only when explicitly driven by the worker
```

The current direction creates several concrete problems:

- graph ownership is split between the sync client that initiates operations
  and the worker that owns their observable lifecycle;
- local mutation durability spans a sync-owned pending store and a worker-owned
  database transaction, leaving the ownership of crash consistency unclear;
- authoritative pull application is initiated from sync and reaches into
  worker storage through callbacks instead of entering the worker's serialized
  command stream;
- graph switch, sign-out, shutdown, mutation, pull application, and Timeline
  presentation fencing cannot be inspected as one worker-owned state machine;
- the injected `graph_backend` is effectively an inverted service API rather
  than a narrow dependency needed by a synchronization library; and
- code-level package separation does not produce runtime authority separation,
  because the callback calls are direct calls within one Worker Domain.

The intended invariant is that every decision that reads or modifies
`Engine.t` originates from `logseq_db_worker`. `logseq_sync` may validate remote
data and request synchronization work, but it must not control the engine.

## Proposal

Invert managed-session orchestration so `logseq_db_worker` is the runtime
engine and `logseq_sync` is a subordinate synchronization state machine and
effect producer.

### Make the worker the sole managed-session coordinator

Add a worker-owned managed coordinator that serializes every event affecting a
managed graph:

```text
Application command --------------------+
Authentication result -----------------+
Graph selection ------------------------+
Engine operation result ----------------+--> worker coordinator
Sync transport event -------------------+        |
Timer / lifecycle event ----------------+        +--> Engine / storage
Timeline presentation acknowledgement --+        +--> Logseq_sync.Api
```

The coordinator owns at least:

```ocaml
type managed_state =
  { engine : Engine.t option
  ; graph_state : graph_state
  ; sync : Logseq_sync.Api.t
  ; account_generation : int
  ; graph_generation : int
  ; presentation_generation : int
  }
```

The exact private representation may contain catalog, bootstrap, E2EE, pending
request, and recovery state. Those facts remain worker-owned orchestration data
even when their protocol payloads are produced by `logseq_sync`.

Graph open, close, switch, retry, cache deletion, sign-out, and shutdown become
worker coordinator transitions. The worker calls `Engine.open_`, `Engine.close`,
and other engine operations directly and publishes `graph_state` from the same
serialized boundary.

### Remove the graph backend from `logseq_sync`

Delete the complete `Logseq_sync.Api.graph_backend` contract, not only its
`open_graph` and `close_graph` callbacks. The sync client must not retain an
opaque `Engine.t` handle or call back into:

- checkpoint or database reads;
- local mutation preparation or duplicate handling;
- projection reset or encoded projection;
- authoritative transaction staging;
- checkpoint persistence; or
- graph lifecycle operations.

`Logseq_sync.Api.dependencies` retains only capabilities intrinsic to
synchronization, such as runtime scheduling, remote transport, artifacts,
secrets, crypto, and event delivery.

### Drive sync through explicit events and effects

Reshape the sync API around worker-supplied facts and sync-owned effects. The
conceptual interface is:

```ocaml
type event =
  | Account_authenticated of account
  | Account_signed_out
  | Graph_attached of graph_context
  | Graph_detached
  | Local_batch_committed of pending_batch
  | Authoritative_batch_applied of apply_result
  | Authoritative_batch_failed of string
  | Transport_message of string
  | Foreground_changed of bool
  | Timer_elapsed of timer

type effect =
  | Request_token of token_request
  | Fetch_catalog of catalog_request
  | Download_snapshot of snapshot_request
  | Connect_websocket of websocket_request
  | Send_pull of pull_request
  | Submit_batch of submission
  | Apply_authoritative_batch of authoritative_batch
  | Pause_sync of string

val handle : t -> event -> effect list
```

These names are illustrative rather than a specification. The important
direction is that the worker feeds committed local facts into sync and interprets
sync effects. `logseq_sync` never obtains an engine capability.

Remote HTTP/WebSocket execution may remain in a sync-owned effect runner inside
the same Worker Domain. Its completions must re-enter the worker coordinator as
events before they can affect graph or database state. Eio fibers must not call
`Engine` directly.

The selected structure is a sync-owned reducer plus a sync-owned effect runner:

```text
worker coordinator
  -> sync reducer
       -> sync-only effects
            -> sync effect runner
                 -> completion posted to worker mailbox
                      -> generation fence
                           -> sync reducer or worker Engine command
```

The reducer owns deterministic protocol state and derives `sync_phase`. The
effect runner owns token, HTTP, WebSocket, timer, artifact, and crypto execution.
It may publish completion events but cannot synchronously re-enter the worker
coordinator, block while waiting for an Engine result, or invoke a database
callback. Effects requiring database work are returned to the worker as
explicit worker effects.

### Make local mutation and its outbox record atomic

The worker owns the complete local mutation path:

```text
Application mutation
  -> worker validates and plans
  -> Engine atomically commits projected mutation and durable outbox entry
  -> worker reports Local_batch_committed to logseq_sync
  -> logseq_sync schedules or submits the durable batch
```

The durable outbox entry contains the normalized mutation identity, fingerprint,
encoded remote transaction, ordering metadata, and submission state required to
recover after restart. Sync-owned encoding and encryption may be invoked while
preparing the worker transaction, but successful encoding is only preparation;
the worker remains the sole commit authority.

The atomic boundary must exclude both crash windows:

- a projected database mutation committed without a durable submission record;
  and
- a durable submission record committed for a projected mutation that did not
  commit.

After restart, the worker restores the engine and durable outbox before it tells
`logseq_sync` to advance synchronization.

Outbox ownership is split deliberately along semantic and transactional
boundaries:

- `logseq_sync` owns the outbox codec, legal submission-state transitions,
  normalization, transaction encoding, encryption, fingerprinting,
  deduplication identity, retry policy, acknowledgement interpretation, and
  uncertain-submission recovery rules; and
- `logseq_db_worker` owns the persisted records, indexed ordering fields,
  atomic insert/update/removal operations, restart loading, and the transaction
  that commits an outbox change together with its corresponding database
  change.

The worker does not invent an outbox transition. Sync produces an immutable
prepared record or validated transition, the worker commits it, and only the
worker's successful commit result permits sync to advance its in-memory state.
The sync-owned codec may operate on immutable database values supplied as
inputs, but it receives no `Engine.t` capability.

### Make authoritative application a worker command

Inbound synchronization follows the opposite direction:

```text
logseq_sync receives, validates, decrypts, and decodes a server batch
  -> emits Apply_authoritative_batch
  -> worker invokes Engine.apply_authoritative
  -> Engine atomically commits authoritative data, projection/rebase, and checkpoint
  -> worker reports Authoritative_batch_applied
  -> logseq_sync advances its cursor and sync_phase
```

The sync client may reject malformed continuity, encryption, or checksum data
before producing an effect. It may not advance its authoritative cursor until
the worker reports a successful atomic commit.

Submission acknowledgement follows the same rule. Server acknowledgement may
change sync protocol state, but removal or state transition of a durable outbox
entry occurs through the worker-owned storage transaction.

### Preserve owner-specific public phases

The phase split remains:

- `Logseq_sync.Api.sync_phase` reports only synchronization activity;
- `Logseq_db_worker.graph_phase` reports engine and graph lifecycle; and
- the app-owned `Journal_startup.startup_phase` reports what blocks journal
  presentation.

Worker ownership of operational startup does not move UI presentation state
into the worker. `Ready` still depends on the current worker `Graph_open` fact
and the current Timeline presentation acknowledgement, and remains independent
of `sync_phase = Current`.

The worker publishes operational facts required by the app reducer. The app
continues to own copy, layout selection, structured startup errors, and
declarative recovery presentation.

### Put catalog and bootstrap workflow state in the worker

The worker owns the ordered account-to-open-graph workflow, including when to
discover a catalog, accept graph selection, inspect a local mirror, prepare a
remote snapshot, replace or retain a mirror, open or close an engine, attach a
committed graph to sync, and recover or shut down. These decisions are fenced by
the worker's account, graph, and presentation generations.

`logseq_sync` provides coarse-grained protocol operations rather than exposing
individual wire encoders to the worker. Representative operations are:

```ocaml
val discover_catalog : t -> account_scope -> catalog_operation
val prepare_remote_snapshot : t -> graph_scope -> snapshot_operation
val begin_reconciliation : t -> attached_graph -> effect list
```

`prepare_remote_snapshot` may acquire protocol tokens, request metadata,
download an artifact, unlock or decrypt E2EE data, and validate checksums inside
the sync package. Its successful result is a validated staged artifact, not an
installed or opened graph:

```ocaml
type staged_snapshot =
  { path : string
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; graph_metadata : graph_metadata
  }
```

The worker generation-fences that result, installs it through worker-owned
storage, opens `Engine`, publishes `Graph_open`, and only then reports an
attached committed graph context to sync. A valid local mirror can be opened and
presented before catalog refresh or online reconciliation completes.

E2EE follows the same split. Sync owns key-envelope protocol, password
validation, crypto, and secret custody. The worker owns the operational
`Awaiting_e2ee_password` barrier and decides when a successful protocol result
allows snapshot installation or graph open. Raw keys do not become worker
orchestration data.

### Keep one runtime Domain without using it as an ownership shortcut

This proposal does not require a new OCaml Domain or process. The worker
coordinator, sync state machine, sync effect runner, `Engine`, and storage may
remain in the existing dedicated Worker Domain. Direct calls are acceptable in
the worker-to-sync direction.

The runtime invariant is directional authority, not memory isolation:

```text
UI/Bonsai Domain
  -> Worker message queue
  -> dedicated Worker Domain
       -> worker coordinator
            -> Engine / storage
            -> Logseq_sync.Api
```

### Cut over without compatibility paths

The eventual implementation is an all-at-once architectural cutover:

1. Define the worker managed coordinator event model and serialization rules.
2. Define the subordinate sync event/effect API.
3. Move graph open, close, switch, and shutdown orchestration into the worker.
4. Move local mutation durability and the outbox into one worker-owned atomic
   transaction.
5. Move authoritative application, projection/rebase, checkpoint persistence,
   and outbox acknowledgement into worker commands.
6. Re-enter every asynchronous sync completion through the worker coordinator.
7. Delete `graph_backend`, the sync-owned engine handle, and all direct sync to
   Engine callbacks.
8. Replace tests with worker coordinator, sync reducer, crash consistency,
   generation fencing, and cross-layer composition tests.

Do not retain aliases, forwarding callbacks, dual pending stores, legacy
mutation paths, or fallback orchestration.

## Decision

Adopt worker-owned managed sync orchestration as described above. The worker
coordinator is the sole serialized authority for graph lifecycle, Engine access,
local storage operations, durable outbox commits, authoritative application,
and generation fencing. `Logseq_sync.Api` is a subordinate state machine with
opaque events, effects, completions, codecs, and protocol planning operations;
it receives no Engine or graph-backend capability.

Local mutations publish only after the worker atomically commits their durable
outbox records. Authoritative batches advance sync state only after the worker
atomically commits data, checkpoint, and outbox changes. Async sync completions
and local storage operations return through the worker coordinator before they
can affect managed-session state.

## Alternatives considered

### Keep the injected graph backend

The worker can continue injecting direct Engine callbacks while documenting
that worker graph state is canonical. This preserves the current implementation
and avoids a new event/effect handshake, but the sync client remains the
effective orchestrator and continues to initiate database work outside the
worker command stream.

### Move only open and close into the worker

Removing `open_graph` and `close_graph` while retaining checkpoint, mutation,
projection, staging, and persistence callbacks would improve lifecycle naming
without moving the engine. Sync would still decide when and how the database is
mutated, so local mutation and authoritative application would retain split
transaction ownership.

### Put sync and database in separate Domains or processes

Runtime isolation would force explicit serialization and could prevent direct
Engine access by construction. It also adds payload copying, cancellation,
shutdown, error propagation, and lifecycle complexity without resolving which
component owns the transaction. The authority inversion should be completed
inside the current Worker Domain before considering stronger isolation.

### Let the Application orchestrate worker and sync independently

The app could observe sync and graph state and issue commands to both packages.
This would move operational races and generation fencing into UI composition,
make headless worker use harder, and allow presentation lifecycle to control
database consistency. The Application should remain a consumer of worker-owned
operational state.

## Acceptance criteria

- `Logseq_sync.Api` has no graph backend, engine handle, database callback,
  graph lifecycle operation, or worker package dependency.
- `logseq_db_worker` owns a single serialized managed coordinator for Application
  commands, sync effects and completions, engine results, timers, lifecycle
  events, and presentation acknowledgements.
- Graph open, failure, close, switch, retry, sign-out, and shutdown transitions
  originate in the worker and update canonical `graph_state` at the engine
  composition boundary.
- Every local mutation and its durable outbox record commit atomically under
  worker ownership before sync submission can begin.
- Restart restores committed projected data and exactly the corresponding
  durable outbox entries without reconstructing intent from UI state.
- Every authoritative batch is validated by sync, committed by the worker, and
  acknowledged back to sync before the authoritative cursor advances.
- Authoritative data, projection/rebase, checkpoint persistence, and durable
  outbox acknowledgement have one tested atomic commit boundary.
- Asynchronous HTTP, WebSocket, token, timer, and artifact completions re-enter
  the worker coordinator and are rejected when their account, graph,
  presentation, connection, or lifecycle generation is stale.
- `sync_phase`, `graph_phase`, and app-owned `startup_phase` remain independent;
  no aggregate compatibility phase is introduced.
- Application code sends operational commands to the worker and does not
  independently coordinate a sync client with an engine.
- Focused sync reducer, worker coordinator, engine atomicity, restart recovery,
  graph-switch, shutdown, source-boundary, Application integration, and full
  repository tests pass.
- `spec-dev-tool check --all` succeeds after the decision is implemented.

## Implementation evidence

- `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml` defines the
  serialized `Managed_coordinator`, owns `Engine.t` and `Api.local_store`, and
  interprets sync effects and completions.
- `logseq_sync/spec/api.mli` exposes opaque events, sync effects, completions,
  local operations, authoritative planning, outbox codecs, and commit-result
  acknowledgements without a graph backend or Engine capability.
- `logseq_db_storage/lib/sync_outbox_store.ml` and
  `logseq_db_storage/lib/storage_session.ml` persist ordered outbox records and
  commit them with mutation or authoritative metadata transaction boundaries.
- `logseq_db_worker/lib/engine.ml` restores durable outbox projection on open,
  atomically applies authoritative data with checkpoint and outbox state, and
  exposes no obsolete projection or checkpoint compatibility entry points.
- `test/source_boundary_test.ml`, `logseq_db_worker/test/test_storage_atomicity.ml`,
  `logseq_db_worker/test/test_bonsai_service.ml`, and the `logseq_sync` scenario
  suite cover the package boundary, ownership composition, atomicity, codec,
  generation, and lifecycle behavior.
- `dune build @all`, `dune build @fmt`, `dune runtest`, the focused Flutter
  adapter/widget tests through `bonsai-flutter exec`, and
  `spec-dev-tool check --all` pass.

## Consequences

- The worker service has one explicit managed coordinator and owns the
  `Engine.t`, local store, graph lifecycle, and generation counters.
- The sync package retains protocol, transport, crypto, checksum, outbox codec,
  transition validation, and reducer responsibilities without retaining worker
  database capabilities.
- SQLite stores the managed outbox in ordered worker-owned records. Synced
  mirrors initialize this schema after ownership validation; snapshot and native
  graph opens remain byte-preserving.
- Local mutation publication, authoritative apply, checkpoint persistence, and
  outbox acknowledgement use worker-owned transaction boundaries.
- The old graph backend, sync-owned pending-file persistence, direct projection
  and checkpoint compatibility entry points, and generic sync mutation API are
  removed.
- New orchestration work must extend the event/effect boundary and worker
  coordinator rather than introduce direct sync-to-Engine callbacks.

## Risks

- The worker becomes a larger orchestration boundary. Its coordinator must be
  separated from protocol encoding and UI presentation so it does not become a
  second sync implementation or an Application domain model.
- Moving the pending outbox can accidentally change retry ordering,
  deduplication, uncertain-submission recovery, E2EE encoding, or checksum
  behavior. Existing remote protocol fixtures must remain authoritative.
- A worker-driven effect loop can deadlock if sync waits synchronously for an
  Engine result while the serialized coordinator waits for the sync call to
  return. Sync effects and their completions must be explicit and non-blocking.
- Sync transport fibers and worker commands run in the same Domain and can
  interleave cooperatively. Generation fencing is still required even without
  parallel Domain execution.
- Atomic mutation plus outbox persistence may require changing the worker
  storage schema and transaction API. The design must not emulate atomicity with
  two independently committed stores.
- Authoritative apply failure must leave sync state, checkpoint, projection,
  and outbox acknowledgement unchanged. Partial recovery paths would recreate
  split authority.
- Removing the graph backend is a broad breaking cutover across sync scenarios,
  worker services, CLI/test fixtures, and Application integration.

## Questions

- None. The user confirmed sync-owned outbox semantics and codec over
  worker-owned records and atomic commits; a sync-owned reducer and effect
  runner whose completions always re-enter the worker coordinator; and
  worker-owned catalog/bootstrap workflow state using coarse-grained sync-owned
  protocol operations.
