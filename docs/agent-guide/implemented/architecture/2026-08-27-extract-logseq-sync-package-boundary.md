# Extract Logseq Sync Package Boundary

## Problem

All managed-sync production modules currently compile inside the
`logseq_db_worker` library. This placement makes the build graph imply that sync
is an implementation detail of the worker, even though sync already has its own
state machine, capability-indexed actions, wire protocol, persistence model,
transport, bootstrap flow, and E2EE boundary.

The desired architecture is a strict dependency chain:

```text
logseq_db_types
  |-- graph UUID and schema types
  `-- shared worker and sync protocol values
          |
          v
logseq_db_storage
  |-- DataScript transaction and persistence interfaces
  |-- SQLite storage
  `-- admission and codec
          |
          v
logseq_sync
  |-- manager, actions, and startup capabilities
  |-- catalog and bootstrap
  |-- wire protocol, replay, and pending intents
  |-- E2EE
  `-- HTTP and WebSocket transports
          |
          v
logseq_db_worker
  |-- graph Engine
  `-- Bonsai worker service
```

The defining invariant is that `logseq_sync` must not compile against
`logseq_db_worker`, directly or transitively. `logseq_db_worker` is the final
composition layer and may depend on all three lower packages.

Moving the current `sync_*.ml` files is not sufficient. The current source graph
contains these worker-owned dependencies:

| Current sync module | Current worker dependency | Reason |
| --- | --- | --- |
| `Sync_catalog`, `Sync_http`, `Sync_manager`, `Sync_meta`, `Sync_mirror`, `Sync_pending`, `Sync_protocol`, `Sync_replay`, `Sync_e2ee_session`, `Sync_platform_crypto` | `Graph_types` | UUID and schema values |
| `Sync_http`, `Sync_manager`, `Sync_pending`, `Sync_websocket_eio` | `Protocol` | request limits, mutation requests, sync activity, and JSON codecs |
| `Sync_replay` | `Storage_session` | staged DataScript transactions and atomic metadata commit |
| `Sync_mirror` | `Logseq_sqlite_storage` and `Admission` | mirror restore, snapshot activation, checkpoint, and schema admission |
| `Sync_tx` | `Logseq_sqlite_codec` | Transit transaction decoding |

There is also a concrete reverse dependency from storage back into sync:

```text
Sync_mirror -> Logseq_sqlite_storage -> Sync_meta
Sync_replay -> Storage_session -> Logseq_sqlite_storage -> Sync_meta
```

If the current modules were merely assigned to new Dune libraries, this reverse
edge would create a package cycle between `logseq_db_storage` and `logseq_sync`.

`Sync_pending` creates a second ownership problem. A durable pending entry stores
an entire `Protocol.request`, even though the sync queue needs only a stable
mutation intent and the information required to replan it after authoritative
replay. This couples sync persistence to the worker's complete request envelope
and makes unrelated worker protocol changes part of the sync storage format.

The current public library also combines portable sync policy with runtime-specific
implementations:

- Eio, HTTPun, TLS, and HTTPun WebSocket own network execution;
- SQLite and DataScript own graph persistence and replay;
- `sync_gzip_stubs.c` requires system zlib;
- `sync_platform_crypto_stubs.c` dynamically resolves the Apple host capability
  `logseq_journal_crypto_json`.

The extraction must preserve the implemented sync decisions: capability-indexed
offline startup, serialized manager ownership, WebSocket-only authoritative pull
and transaction submission, local-first pending intents, generation fencing,
atomic replay, checksum validation, and native custody of private key material.
It must not introduce a second transport, compatibility facade, fallback package,
or duplicate implementation path.

This document explores package ownership and migration sequencing only. It does
not authorize edits to the canonical `.mli` files under `spec/`, Dune files, or
production code.

## Proposal

### Treat the arrows as compile-time constraints

Create four independently installable opam packages. Each package owns a wrapped
public OCaml library with the matching public name:

```text
logseq_db_types
logseq_db_storage
logseq_sync
logseq_db_worker
```

Every library exposes an explicit `.mli` surface. No lower library may refer to a
module owned by a higher library, including in tests, default implementations,
virtual-library implementations, foreign stubs, or generated package metadata.

The allowed direct dependencies are:

| Library | Allowed project-library dependencies |
| --- | --- |
| `logseq_db_types` | none |
| `logseq_db_storage` | `logseq_db_types` |
| `logseq_sync` | `logseq_db_types`, `logseq_db_storage`, and the canonical sync specification library |
| `logseq_db_worker` | `logseq_db_types`, `logseq_db_storage`, `logseq_sync` |

Tests may depend upward on the subject they test, but production libraries and
test-support libraries must not create a reverse production edge.

### `logseq_db_types`: shared values, not behavior owners

Move data definitions and codecs required on both sides of a package boundary
into `logseq_db_types`. The initial candidate ownership is:

- `Graph_types`, including UUID, cursor, schema, graph target, page, block, and
  result primitives used by `Protocol`;
- the serializable request, response, mutation, and sync-status values currently
  owned by `Protocol`;
- the structured error values needed to encode and decode those protocol values;
- a new storage-neutral sync checkpoint value containing graph identity, schema,
  applied server cursor, checksum, active/paused status, and last diagnostic.

`logseq_db_types` must remain independent of DataScript, SQLite, Eio, TLS, Bonsai,
Flutter, and native foreign stubs. It may depend on `yojson` for boundary codecs.

The current `Protocol` is a large worker API, not merely a sync protocol. Split it
before package extraction into shared mutation/sync primitives owned by
`logseq_db_types` and a request/response envelope owned by `logseq_db_worker`.
Do not move the complete worker API into `logseq_db_types`, and do not copy any
protocol type or codec. The split must let `Sync_pending`, `Sync_manager`, and the
worker use one canonical mutation identity and one canonical sync activity type.

### Split `Sync_meta` into a shared value and storage implementation

Remove the current mixed responsibility of `Sync_meta`, which owns both sync state
transitions and direct SQLite operations.

Use this ownership instead:

```text
logseq_db_types.Sync_checkpoint
  - immutable checkpoint type
  - validation and equality

logseq_db_storage.Sync_checkpoint_store
  - create/read/update SQLite rows
  - participate in an atomic Storage_session commit

logseq_sync.Sync_state
  - advance cursor and checksum
  - pause on replay/protocol failure
  - interpret the shared checkpoint as sync policy
```

`Storage_session` accepts the lower-level checkpoint type from
`logseq_db_types`; it never accepts a value whose type is declared by
`logseq_sync`. `Logseq_sqlite_storage` implements checkpoint persistence without
importing `logseq_sync`. This removes the storage-to-sync edge while retaining the
atomic transaction-plus-checkpoint commit required by authoritative replay.

Delete the old `Sync_meta` implementation after its responsibilities have moved.
Do not retain aliases or a forwarding module.

### `logseq_db_storage`: graph persistence without sync policy

Move these responsibilities below sync:

- `Admission` and schema inspection;
- `Logseq_sqlite_codec`;
- `Logseq_sqlite_storage`;
- `Storage_session` and staged/atomic transaction APIs;
- checkpoint persistence described above;
- the narrow snapshot activation and mirror-storage operations needed by sync.

The storage package owns SQLite connection lifecycle, DataScript restoration,
commit, checkpoint, and garbage collection. It does not decide whether a pull is
continuous, whether a checksum mismatch pauses sync, when a reconnect occurs, or
how pending intents are recovered.

The expected external dependency set is DataScript, SQLite3,
`persistent_sorted_set_ocaml`, Transit, Yojson, and Unix. Exact dependencies must
be derived from the final Dune module set rather than copied from the current
monolithic opam file.

### `logseq_sync`: sync policy and runtime without worker imports

Move the complete sync ownership into the new package:

| Area | Current modules |
| --- | --- |
| State and capability model | `Sync_manager`, `Sync_action`, `Sync_startup_phase`, `Sync_auth`, `Sync_network_scope`, `Sync_websocket` |
| Catalog and bootstrap | `Sync_catalog`, `Sync_catalog_store`, `Sync_bootstrap`, `Sync_snapshot`, `Sync_mirror` |
| Protocol and replay | `Sync_protocol`, `Sync_replay`, `Sync_pending`, `Sync_tx`, `Sync_tx_encoder`, `Sync_checksum` |
| E2EE | `Sync_e2ee`, `Sync_e2ee_session`, `Sync_graph_key`, `Sync_platform_crypto` |
| Transport | `Sync_http`, `Sync_http_eio`, `Sync_websocket_eio` |

The package exposes one concise wrapped namespace: `Logseq_sync.Manager`,
`Logseq_sync.Action`, `Logseq_sync.Protocol`, and so on. Do not retain redundant
paths such as `Logseq_sync.Sync_manager` or the globally prefixed `Sync_*` public
module names. There must be one public path per concept.

The canonical virtual contracts for action and startup capability remain the
source of truth. If the extraction proceeds, their specification library and
default implementation must move under the `logseq_sync` package together. The
specification may depend on `logseq_db_types` after shared UUID and protocol values
exist, eliminating the current need to duplicate graph contract values inside
`Sync_action`. The approved package-boundary implementation may move and modify
`spec/sync_action.mli` and `spec/sync_startup_phase.mli` in the same cutover. It
must not leave the old specification location or a duplicate contract behind.

`logseq_sync` contains multiple public Dune sublibraries so consumers can choose
runtime weight:

```text
logseq_sync.core       state machines, actions, wire values, E2EE transforms
logseq_sync.storage    replay, pending intents, mirror and bootstrap activation
logseq_sync.eio        HTTP and WebSocket Eio implementations
logseq_sync.platform   zlib and host-crypto adapters
```

These sublibraries depend only from top to bottom within the package and must not
import `logseq_db_worker`. `logseq_sync.core` remains portable and does not link
Eio, Apple crypto, or zlib. The default production composition links the adapter
sublibraries explicitly.

The expected external dependencies of the complete package are:

- `uri`, `yojson`, `digestif`, `uutf`, and Transit;
- DataScript through replay, transaction encoding, and checksum calculation;
- Eio, HTTPun, HTTPun Eio/WebSocket, TLS, CA certificates, Domain-name,
  Bigstringaf, Faraday, Cstruct, and Mirage Crypto RNG for transports;
- Unix and system zlib for file-backed bootstrap;
- the native host crypto symbol for the production platform adapter.

The core sublibrary should not inherit Eio, TLS, SQLite, zlib, or Apple host
requirements merely because the full package provides adapters for them.

### Replace worker request persistence with a sync-owned pending contract

`Sync_pending` must stop storing a complete worker `Protocol.request`. Define one
canonical pending mutation value in `logseq_db_types` or `logseq_sync.core` with
only the stable data needed across restart and authoritative replay:

```ocaml
type pending_mutation =
  { mutation_id : Uuid.t
  ; mutation : mutation_command
  ; encoded_tx : string
  ; outliner_op : string
  ; state : pending_state
  }
```

The exact mutation command type should be the same value consumed by the worker's
mutation planner; it must not be a second JSON interpretation of the command.
Request IDs, response routing, read commands, sync-receive envelopes, and other
worker-only fields do not belong in the durable sync queue.

Changing this shape intentionally replaces `pending-intents-v1.json`. Because the
repository does not preserve backward compatibility, the implementation selects a
new canonical format and deletes the obsolete decoder instead of retaining a
migration or fallback reader. Finding an obsolete pending file fails startup with
an explicit local-cache-recovery requirement. It must never silently delete
possibly unsynchronized local edits.

### Keep `Engine` and the Bonsai service as composition owners

`Engine` remains in `logseq_db_worker` because it combines sync with mutation
planning, outliner behavior, read models, invalidation, backup, graph open/close,
and application request execution. It consumes the lower package APIs but is not
part of the reusable sync runtime.

`Logseq_db_worker_bonsai_service` also remains in `logseq_db_worker`. It owns the
serialized interpreter that:

- sends manager commands and events;
- interprets local and network actions;
- opens, replaces, and closes `Engine.t`;
- bridges Graph requests and Bonsai pushes;
- supplies Eio environment, application-support paths, token acquisition,
  lifecycle scheduling, and native secret capabilities.

This keeps Bonsai and Flutter out of `logseq_sync`. The service depends on
`logseq_sync`; sync never depends on the service or on `Engine`.

### Express Engine interaction as a narrow port

Several current sync actions ultimately invoke `Engine.execute`, but `Sync_action`
must not mention `Engine.t` or `Protocol.response`. Keep the action payloads in
terms of shared values and let the Bonsai service translate them into worker calls.

Where replay and pending recovery require graph mutation behavior, prefer a narrow
`.mli` contract owned below the worker, such as a storage transaction interface or
a mutation-replan callback, over importing `Engine`. The callback must be
synchronous and invoked only by the serialized service/engine owner so extraction
does not weaken the existing single-writer rule.

### Preserve native boundaries as injected adapters

The platform crypto ABI remains outside portable sync policy. `logseq_sync.core`
defines a `Crypto`/`Secret_store` signature or record of capabilities. The Apple
host implementation and `sync_platform_crypto_stubs.c` live in the platform
adapter sublibrary or in the final application host; neither choice may make core
sync depend on `logseq_db_worker`.

Likewise, gzip decompression is exposed as a bounded artifact-decoder capability.
The production zlib implementation may ship in `logseq_sync.platform`, while core
bootstrap policy owns layer limits, file cleanup rules, and validation.

### Migrate by dependency layer without compatibility paths

Use a bottom-up migration so every intermediate build has an acyclic graph:

1. Add source-boundary tests that compute the intended production dependency DAG
   and reject `logseq_sync -> logseq_db_worker` references.
2. Create `logseq_db_types`; move shared types/codecs and update all consumers to
   the new namespace. Delete old module locations in the same cutover.
3. Split `Sync_meta`, then create `logseq_db_storage` and move admission, codec,
   SQLite storage, and session ownership. Remove all storage references to sync.
4. Replace the pending-entry dependency on the complete worker request envelope
   and establish the new durable format policy.
5. Create `logseq_sync`, move the canonical specification implementation and all
   sync modules, foreign stubs, focused tests, and fixtures.
6. Update `Engine`, Bonsai service, CLI, tools, application integrations, and
   source-boundary tests to consume the new wrapped APIs.
7. Split opam metadata and regenerate locked dependency sets from actual package
   ownership. Remove sync-only dependencies from `logseq_db_worker`.
8. Delete old source paths, public re-exports, obsolete test helpers, and duplicate
   package declarations. Do not retain deprecated aliases or fallback libraries.

The steps describe dependency order, not permission to edit Dune or `spec/` during
this exploration. The eventual proposal must turn them into reviewable
behavior-first implementation batches.

### Validation strategy

Before moving implementation, capture current behavior with focused sync tests
and repository-local fixtures. Tests must not depend on a sibling Logseq checkout,
a ClojureScript oracle, or an external runtime CLI. During migration, relocate
tests with their owner instead of leaving all tests in `logseq_db_worker`.

The completed package boundary should be verified by:

- focused tests for each of the four public libraries;
- existing manager, replay, protocol, pending, E2EE, bootstrap, mirror, transport,
  Engine, Bonsai service, application integration, and source-boundary suites;
- `ocamldep -modules` checks over every `logseq_sync` production source;
- Dune package dependency inspection proving that `logseq_sync` has no direct or
  transitive `logseq_db_worker` dependency;
- a source-boundary test rejecting imports of `Logseq_db_worker` and worker-owned
  source paths from the new sync tree;
- build checks for macOS and iOS so foreign stubs, TLS, Eio, and zlib remain
  linkable;
- `dune build @all`, `dune runtest`, formatting checks, and
  `spec-dev-tool check --all`.

## Decision

- Adopt four wrapped opam packages and public libraries with the production
  dependency direction `logseq_db_types -> logseq_db_storage -> logseq_sync ->
  logseq_db_worker`.
- Own graph values, mutation commands/codecs, sync status, managed-graph values,
  and storage-neutral checkpoints in `logseq_db_types`.
- Own admission, DataScript/SQLite codecs and lifecycle, serialized storage
  sessions, and checkpoint persistence in `logseq_db_storage`.
- Own the canonical action/startup specification, manager, wire protocol,
  pending queue, replay, E2EE, transports, and native platform adapters in
  `logseq_sync`, split into `core`, `storage`, `eio`, and `platform`
  sublibraries.
- Keep request/response envelopes, `Engine`, Bonsai service composition, CLI, and
  application request execution in `logseq_db_worker`.
- Persist pending mutation intent in the canonical v2 format without a worker
  request envelope. Treat an obsolete v1 file as an explicit local-cache recovery
  error and retain it for operator action.
- Delete the old worker-owned sync modules, specification location, forwarding
  exports, and mixed `Sync_meta` implementation in the same cutover.

## Alternatives considered

### Move only the pure sync state machine

Extracting Manager, Action, Startup phase, Auth, Catalog, and wire Protocol while
leaving replay, pending, mirror, transport, and E2EE in the worker would produce a
small acyclic library. It would not meet the requested ownership boundary: the
worker would still own most sync behavior, and future protocol changes would span
two competing sync locations.

### Let `logseq_sync` depend on a reduced `logseq_db_worker.core`

Renaming the existing worker library and having sync depend on it would minimize
file movement, but it would preserve the wrong ownership direction. A core library
containing worker protocol and storage would remain an implicit worker dependency,
and the final worker would either form a cycle or require a compatibility facade.

### Invert every dependency through callbacks

Sync could become independent by functorizing UUID, protocol, DataScript,
persistence, filesystem, transport, clocks, and crypto. This maximizes portability
but makes common domain values generative across functor applications, complicates
GADT actions and async event payloads, and shifts too much static structure into
runtime wiring. Shared types and a concrete storage package keep the important
boundaries explicit while reserving capability injection for true platform edges.

### Move `Engine` into `logseq_sync`

This would eliminate the replay-to-engine adaptation boundary, but it would pull
outliner planning, query/read models, backup, graph ownership, and worker request
execution into sync. The resulting package would be another name for the current
monolith and would not be reusable independently.

### Keep forwarding modules during migration

Temporary `Sync_*` aliases under `Logseq_db_worker` would reduce call-site churn,
but they would preserve obsolete public paths and make source-boundary validation
ambiguous. The repository explicitly removes obsolete paths instead of maintaining
compatibility layers, so each migration step must update consumers and delete the
old path in the same cutover.

## Acceptance criteria

- Dune and opam expose the selected `logseq_db_types`, `logseq_db_storage`,
  `logseq_sync`, and `logseq_db_worker` package/library structure.
- The production dependency graph is acyclic and follows exactly
  `types -> storage -> sync -> worker`, allowing worker to depend directly on
  lower layers when needed.
- No production source, specification implementation, test-support library, or
  foreign-stub target owned by `logseq_sync` imports or links
  `logseq_db_worker`.
- `logseq_db_storage` does not import `logseq_sync`; the current `Sync_meta`
  reverse dependency no longer exists.
- Sync pending persistence no longer serializes an entire worker request envelope.
- `Engine` and the Bonsai service remain worker-owned, and all DataScript/SQLite
  mutation continues through one serialized owner.
- Manager/action/startup capabilities, WebSocket-only pull/submission, replay,
  checksum, pending recovery, bootstrap, E2EE, generation fencing, and offline
  startup behavior remain unchanged.
- Canonical action/startup specifications and their implementation belong to the
  sync package without duplicate `.mli` contracts or default implementations.
- Each concept has one public API path; old worker re-exports and source locations
  are deleted.
- `logseq_db_worker` no longer declares sync-only external dependencies that it
  does not use directly.
- Focused package tests, integration tests, macOS/iOS builds, `dune build @all`,
  `dune runtest`, formatting checks, and `spec-dev-tool check --all` succeed.

## Implementation evidence

- Four public package install targets build in dependency order through an
  isolated prefix, and the new package metadata passes opam lint.
- Focused sync tests live under `logseq_sync/test`; the pending tests cover the v2
  value-only format and explicit obsolete-v1 recovery behavior.
- `ocamldep` over every sync production/specification source and Dune dependency
  inspection show no `logseq_db_worker` edge. Source-boundary tests enforce this
  direction and the removal of all old worker paths and exports.
- `dune build @all`, `dune runtest`, and `dune build @fmt` pass after the cutover.
- Flutter tests and analysis pass through the installed `bonsai-flutter` tool.
  macOS debug and unsigned iOS debug builds both pass native object, framework,
  and application-bundle Mach-O verification.

## Consequences

- Sync can compile and be installed without the worker; storage likewise has no
  dependency on sync policy.
- The worker and application now import concise lower-package namespaces, and
  existing consumers of worker-owned `Sync_*` paths must update rather than rely
  on compatibility aliases.
- Checkpoint policy and SQLite persistence are separate while replay still commits
  DataScript changes and checkpoint advancement atomically through
  `Storage_session`.
- The sync core library remains free of Eio, TLS, SQLite, zlib, and Apple-host
  linking requirements; runtime adapters add those dependencies explicitly.
- Existing v1 pending queues cannot be decoded by the new runtime. Startup reports
  the required local-cache recovery instead of deleting or silently migrating
  possibly unsynchronized edits.
- Package metadata and lockfiles now follow actual ownership, so worker metadata
  no longer lists transport, TLS, WebSocket, crypto-RNG, or CA dependencies owned
  by `logseq_sync`.
- Source-boundary tests, `ocamldep`, and Dune dependency inspection enforce the
  package direction and reject reintroduction of old worker paths or reverse
  production edges.

## Risks

- Moving the large `Protocol` module intact may make `logseq_db_types` broader
  than intended; splitting it may touch most worker and application call sites.
- Replacing the pending-intent file format can discard queued local edits if the
  product policy for obsolete files is not explicit.
- Splitting `Sync_meta` can accidentally break the atomicity between authoritative
  DataScript replay and cursor/checksum persistence.
- A wrapped module rename can produce a large mechanical diff that hides semantic
  boundary mistakes unless moves and behavior changes are separated into focused
  commits.
- Moving foreign stubs between packages can expose differences between desktop,
  simulator, and iOS device link behavior.
- Eio/TLS dependencies may leak into the core library if Dune stanzas are not
  split by runtime responsibility.
- Relocating the virtual specification may change Dune default-implementation
  selection and accidentally permit tests to compile against a different action
  implementation.
- Existing uncommitted changes overlap sync, Protocol, Engine, Bonsai service,
  and the canonical specification. Implementation must begin only from a reviewed
  worktree state and must not overwrite unrelated work.

## Questions

- None. The package granularity, Protocol split, obsolete pending-file behavior,
  optional runtime adapters, concise wrapped API, and specification relocation
  were approved on 2026-08-27.
