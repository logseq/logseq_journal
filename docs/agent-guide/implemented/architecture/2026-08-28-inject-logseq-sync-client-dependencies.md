# Inject Logseq Sync Client Dependencies

## Problem

The intended package direction is unambiguous:

```text
logseq_db_types
        ^
        |
logseq_db_storage
        ^
        |
logseq_sync
        ^
        |
logseq_db_worker
```

`logseq_db_worker` may depend on `logseq_sync`; `logseq_sync` must never depend
on `logseq_db_worker`. That compile-time direction already appears in the public
Dune library declarations, but the source boundary is not real yet.

`logseq_db_worker/lib/dune`, `logseq_db_worker/test/dune`, and
`logseq_db_worker/tool/dune` add the implementation object directories
`logseq_sync/lib/.logseq_sync_impl.objs/{byte,native}` to the compiler include
path. `Engine` then recreates a local `Logseq_sync` namespace from physical Dune
names such as `Logseq_sync__logseq_sync_impl__Pending` and
`Logseq_sync__logseq_sync_impl__Replay`. Worker tests and fixture tools refer to
the same physical names directly. These references bypass
`Logseq_sync.Api`, so changing a private sync module can still break the
worker even when the public specification is unchanged.

The current runtime control flow explains why the bypass was introduced:

```text
Logseq_db_worker_bonsai_service
  |
  | creates and commands
  v
Logseq_sync.Api
  |
  | graph_backend callbacks containing raw sync concerns
  v
Logseq_db_worker.Engine
  |
  | private implementation imports
  v
Mirror, Graph_key, E2ee, Pending, Tx, Tx_encoder, Protocol, Replay
```

The client owns manager orchestration and transport timing, but the graph
backend passes a raw authoritative WebSocket payload into `Engine` and asks
`Engine` for an already encoded pending WebSocket batch. As a result, `Engine`
still owns or understands all of the following sync details:

| Worker responsibility today | Private sync implementation used |
| --- | --- |
| Resolve and bootstrap a managed mirror | `Mirror` |
| Unlock, parse, encrypt with, decrypt with, and clear graph keys | `E2ee`, `Graph_key`, `Platform_crypto` |
| Encode a local DataScript transaction | `Tx_encoder` |
| Persist, submit, accept, requeue, and rebase local intents | `Pending`, `Tx` |
| Encode transaction batches and decode server frames | `Protocol` |
| Atomically apply an authoritative pull and checkpoint | `Replay` |

This is not only a namespace problem. Publishing those modules would make a
private implementation graph into the supported API without correcting the
split ownership.

The opposite half of the problem is inside the current `Logseq_sync.Client`.
Its `create`
currently receives an Eio switch, an entire `Eio_unix.Stdenv.base`, a graph
backend, a callback, and a `platform` value. The implementation nevertheless
selects and invokes concrete effects directly:

- `Http_eio` and `Websocket_eio` for network execution;
- `Eio.Stdenv` and `Eio.Time` for network, clocks, fibers, and reconnect sleeps;
- `Catalog_store`, `Mirror`, `Bootstrap`, `Sys`, and `Unix` for files and local
  persistence;
- `Artifact_decoder` for gzip handling; and
- `Platform_crypto` through `default_platform` for Apple host crypto and secret
  custody.

`default_platform` means the public client has an implicit production choice in
addition to the dependencies supplied by its caller. It also leads
`logseq_db_worker.Engine` to expose its own `default_crypto` and
`unlock_graph_key` values from the same private adapter. Tests can replace only
some of this environment, and the public contract does not enumerate all
effects required to start a client.

The repository currently uses `logseq_sync/spec/client.mli` as the Dune virtual
module contract; there is no `logseq_sync/spec/api.mli`. The selected replacement
renames the virtual module to `Api`, moves the canonical contract to
`logseq_sync/spec/api.mli`, and exposes it as `Logseq_sync.Api`. No compatibility
copy or alias of `Logseq_sync.Client` should remain.

The target architecture must establish both invariants at once:

1. every `logseq_db_worker` production, test, and tool source may use only the
   installed public API of `logseq_sync`; and
2. every effect or host capability used by a sync client instance is supplied
   explicitly when that instance is created.

This exploration covers the public boundary and responsibility transfer. It
does not authorize implementation or Dune edits while the document remains in
the exploring lifecycle.

## Proposal

### Make the public specification the only worker-visible sync surface

Retain one Dune virtual module as the canonical API and one default
implementation library. The implementation library may contain private modules,
but downstream source code must not be able to compile against their physical
names.

The final cutover must delete all manual `.logseq_sync_impl.objs` include paths.
`logseq_db_worker`, its Bonsai service, its tests, and its tools may link only the
public `logseq_sync` library and use names declared in the canonical virtual
`.mli`. They must not depend on `logseq_sync.impl`, import a physical Dune module
name, or gain a public alias for `Mirror`, `Pending`, `Replay`, `Protocol`, or the
other implementation modules.

This is an all-at-once boundary replacement. Replace the current `Client`
virtual module with `Api`, delete `logseq_sync/spec/client.mli`, and do not copy
it, re-export it, or retain a forwarding `Logseq_sync.Client` module for
compatibility.

### Separate values from injected effects

The public create contract should have two top-level inputs:

- `config`, containing inert values such as the managed-sync origin and bounded
  policy limits; and
- `dependencies`, containing every operation that can observe or change the
  host environment.

The shape below is illustrative rather than a compilation-ready specification:

```ocaml
type config =
  { managed_sync_origin : Uri.t
  ; limits : limits
  }

type ('graph, 'mutation, 'mutation_result) dependencies =
  { runtime : runtime
  ; transport : transport
  ; local_store : local_store
  ; artifact_store : artifact_store
  ; secrets : secrets
  ; crypto : crypto
  ; graph : ('graph, 'mutation, 'mutation_result) graph_backend
  ; on_event : event -> unit
  }

type ('graph, 'mutation, 'mutation_result) t

val create
  :  config
  -> ('graph, 'mutation, 'mutation_result) dependencies
  -> (('graph, 'mutation, 'mutation_result) t, create_error) result
```

Individual records should be abstract values built through validating public
constructors. This avoids enormous structural records in callers while still
making construction explicit. There must be no `default_platform`, default
transport, global mutable runtime, ambient application-support directory, or
fallback implementation selected inside `create`.

Pure parsing, state transitions, wire codecs, E2EE transformations, pending
state transitions, and replay calculations remain private implementation code;
they are not dependencies. The injected boundary covers effects and host-owned
resources.

### Inject these capability groups at creation

The canonical specification should account for every effect currently reachable
from the sync client implementation:

| Capability | Required operations | Current concrete owner |
| --- | --- | --- |
| Runtime | supervised fork, cancellation, serialized delivery, monotonic sleep, deterministic shutdown | Eio switch, streams, promises, and `Stdenv` clocks |
| HTTP | bounded request and bounded artifact download with progress and cancellation | `Http_eio` |
| WebSocket | connect, send, receive, close, and connection cancellation | `Websocket_eio` |
| Local store | catalog load/save, mirror inspect/activate/delete, pending bytes load/commit/delete, durable rename/fsync semantics | `Catalog_store`, `Mirror`, `Pending`, `Sys`, `Unix` |
| Artifact store | allocate staging targets, peel/decompress the downloaded artifact, clean temporary files | `Bootstrap`, `Artifact_decoder`, direct filesystem calls |
| Secrets | inspect/unlock/delete account secrets and load/save/delete wrapped graph keys | current `platform` callbacks |
| Crypto | private-key decryption, graph-key decryption, AES-GCM encryption/decryption, secure clearing | `E2ee`, `Graph_key`, `Platform_crypto` |
| Graph backend | database ownership, mutation planning, projection, atomic authoritative commit, checkpoint read, and close | `Logseq_db_worker.Engine` and `Storage_session` |
| Events | state, token challenge, bootstrap progress, and graph invalidation delivery | Bonsai service callback |

An implementation may provide public constructors for production Eio, Unix, or
Apple adapters, but construction must occur above `create` and the constructed
value must be passed explicitly. Such constructors are supported adapter API,
not implicit defaults. Alternatively the application composition layer may
implement the records itself. In either case, `Api` must not reach around the
injected value to call the concrete adapter directly.

`Eio.Switch.t` remains an explicitly supplied lifetime token so the implementation
retains structured lifetime ownership. The broad `Eio_unix.Stdenv.base` is
removed: it must not remain as a way to discover arbitrary network and clock
capabilities after creation. The exact transport, clock, sleep, and scheduling
operations used by sync are named in the injected records.

The Apple implementation remains a host adapter. `logseq_sync` should know only
the `crypto` and `secrets` contracts supplied at creation, not whether those
callbacks ultimately cross a Swift bridge, a C symbol, or an in-memory test
double. No ClojureScript source, Logseq CLI process, or repository-external CLI
is part of this architecture or its test oracle.

### Move sync semantics out of `Engine` instead of publishing private modules

`logseq_sync` should own all sync-specific state and formats:

- catalog reconciliation and mirror lifecycle policy;
- graph-key lifetime and E2EE encoding/decoding;
- pending intent serialization and state transitions;
- transaction wire encoding and server-frame decoding;
- submission acknowledgement and uncertain-submission recovery;
- authoritative replay calculation and pending rebase policy; and
- reconnect, pull, and submission orchestration.

`logseq_db_worker.Engine` should own database-specific behavior:

- exclusive graph ownership and SQLite/DataScript session lifetime;
- outliner mutation validation and planning;
- current authoritative and projected database values;
- atomic transaction-plus-checkpoint persistence;
- worker query, mutation response, and invalidation construction; and
- graph close.

The public `graph_backend` is the dependency-inversion seam. Its type is declared
by the sync specification, implemented by `logseq_db_worker`, and passed to
`create`. This does not create a compile-time reverse dependency: callbacks let
the lower sync package invoke behavior implemented by the upper worker package.

The current raw methods are the wrong abstraction:

```text
pending_batch      : graph -> raw websocket payload option
apply_authoritative: graph -> raw websocket payload -> result
```

They force the worker to own `Protocol`, `Pending`, and `Replay`. Replace them
with database operations over public, normalized values. The eventual signature
must support these phases:

1. The sync client resolves or activates the mirror through the injected local store and
   asks the graph backend to open the resulting database target.
2. For a managed local mutation, the backend plans and validates against the
   projected database and returns a normalized prepared change. The sync client encrypts
   and encodes it, durably appends the pending intent, and only then asks the
   backend to publish the new projection. This preserves the current
   pending-before-visible ordering.
3. The sync client chooses queued entries, marks them submitted durably, encodes the wire
   batch privately, and sends it through the injected WebSocket.
4. The sync client decodes an authoritative frame privately. The backend stages and
   atomically commits normalized transaction operations plus the next public
   `Sync_checkpoint` value. The sync client then rebases its pending intents and asks the
   backend to replace the projected database.
5. The sync client emits a public invalidation after the database and pending state have
   reached a consistent state.

The prepared-local-change and authoritative-commit values should contain only
shared database types already owned by `logseq_db_types` or narrowly declared
public boundary types. They must not expose `Pending.entry`, `Replay.result`,
`Protocol.server_message`, `Graph_key.t`, a raw WebSocket frame, or an Engine
`Storage_session.t`.

Managed graph mutations must pass through a public `Logseq_sync.Api` operation,
with worker-owned mutation request and result types carried as type parameters,
so the client can enforce this ordering. The Bonsai adapter should no longer call
`Engine.execute` and then merely call `notify_local_change`; that wake-only API
cannot transfer the prepared transaction and leaves pending ownership in the
engine. Non-managed snapshot and native-local graph requests may continue to
execute directly in `Engine` without constructing a sync client.

### Compose once in `logseq_db_worker_bonsai_service`

The Bonsai service remains the application composition root. At managed-session
initialization it should:

1. construct the worker graph backend from production `Engine` dependencies;
2. construct explicit runtime, transport, local-store, artifact, crypto, and
   secret adapters;
3. call the sole public sync `create` operation once; and
4. retain the opaque client and graph handles required to route worker commands.

There should be no `create_with_platform` plus `create` default pair. Production
and tests call the same `create`, differing only in the injected dependency
values. The module-level `service` may still be a fully composed production
value, provided every dependency was explicitly supplied during its construction
and no client instance consults a hidden default later.

`Engine.dependencies` should lose sync crypto and graph-key unlock callbacks.
Those belong to the sync client dependencies. `Engine.default_crypto`,
`Engine.unavailable_crypto`, and `Engine.unlock_graph_key` should be deleted
rather than re-exported through a compatibility layer.

### Move or delete tests that depend on implementation units

Tests of pending serialization, mirror activation, replay, graph-key handling,
catalog persistence, checksum, and wire protocol belong under `logseq_sync/test`
where private implementation tests may access package-local modules through
normal Dune ownership.

Worker tests should verify only the public composition contract and observable
database behavior. Tests and fixture helpers that require
`Logseq_sync__logseq_sync_impl__*` should be rewritten through the public client
API when they protect a cross-package behavior; tests that merely duplicate
private sync unit coverage should be deleted. Fixture generation must use
public constructors or checked-in fixtures, not private module include paths.

No replacement test may invoke ClojureScript, the Logseq CLI, or code outside
this repository. The deleted cross-runtime CLJS/CLI oracle must not return as a
fallback.

## Decision

- Replace the `Client` virtual module with the sole public
  `Logseq_sync.Api` contract in `logseq_sync/spec/api.mli`. Delete the obsolete
  client contract and retain no alias or forwarding module.
- Require callers to pass an `Eio.Switch.t`, inert configuration, and one
  validated dependency value to `Api.create`. The dependency value explicitly
  contains runtime, transport, local-store, artifact-store, secrets, crypto,
  graph-backend, and event-delivery capabilities.
- Keep production Eio, Unix, and Apple implementations behind explicit public
  adapter constructors. The client retains those constructed capability values
  and does not discover an `Eio_unix.Stdenv.base`, application-support path,
  native crypto implementation, or other fallback after creation.
- Move protocol encoding and decoding, pending durability and submission,
  authoritative replay and rebase, E2EE, catalog reconciliation, mirror policy,
  and reconnect orchestration into `logseq_sync`.
- Restrict `Logseq_db_worker.Engine` to graph and database behavior: graph
  lifetime, mutation planning, projected state, atomic authoritative commit with
  checkpoint persistence, query responses, invalidation, and close.
- Route every managed mutation through `Logseq_sync.Api.mutate`. The sync client
  durably appends the normalized pending intent before asking the graph backend
  to publish its prepared projection.
- Remove physical Dune include paths and every worker production, test, or tool
  reference to private sync implementation units. Move retained sync tests under
  `logseq_sync/test` and delete redundant private worker tests.

## Alternatives considered

### Publish every sync module used by `Engine`

This would remove the physical Dune names, but it would make `Pending`, `Replay`,
`Mirror`, `Graph_key`, and the raw wire protocol permanent consumer contracts.
It would preserve split ownership and allow any consumer to bypass client
serialization. It is not selected.

### Keep the private include paths as a friend-library mechanism

Dune physical names and `.objs` paths are implementation details rather than a
friend API. This mechanism is not installed-package-safe and cannot be checked by
the virtual `.mli`. It is the behavior this decision is intended to remove.

### Move `logseq_sync` behavior back into `logseq_db_worker`

This would eliminate the callback boundary but reverse the completed package
extraction. A standalone sync client would again be impossible, and transport,
secret, and sync state-machine changes would be worker changes. It is not
selected.

### Make `logseq_sync` depend on `logseq_db_worker`

This would let sync call `Engine` directly but would create a package cycle
because the worker is required to depend on sync. Dependency injection through a
public backend expresses the same runtime call direction without a compile-time
reverse edge.

### Keep `Stdenv` and `default_platform` as sufficient injection

An entire Eio environment is an ambient capability, and `default_platform`
selects host behavior without a caller decision. This leaves tests and alternate
hosts unable to account for every effect at construction. It is not selected.

### Expose raw payloads through the graph backend

This is the current shape. It minimizes callback types but makes the database
worker decode and produce sync wire messages. Normalized database values are a
larger but stable boundary and keep wire compatibility inside `logseq_sync`.

### Use an OCaml functor instead of runtime dependency records

A functor can enforce capability provision at compile time, but it creates a
new module instance per composition and makes runtime test doubles and multiple
clients more cumbersome. The requested lifecycle is instance-oriented and
explicitly centered on `create`, so validated dependency values are selected.

## Acceptance criteria

- The production package graph remains `logseq_db_types` ->
  `logseq_db_storage` -> `logseq_sync` -> `logseq_db_worker`, where each arrow
  means “is depended on by”; there is no direct or transitive worker dependency
  from `logseq_sync`.
- `logseq_db_worker/lib`, `bonsai`, `test`, and `tool` contain no
  `Logseq_sync__*` reference and no compiler include path into
  `.logseq_sync_impl.objs`.
- Every worker reference to sync resolves through the one installed public
  virtual-module contract. The worker links `logseq_sync`, not
  `logseq_sync.impl` or another public implementation-detail sublibrary.
- `logseq_sync/spec/api.mli` is the sole handwritten public sync contract and is
  exposed as `Logseq_sync.Api`. The obsolete `spec/client.mli` is deleted in the
  same cutover; there is no copied interface, `Logseq_sync.Client` forwarding
  module, or compatibility alias.
- `create` receives a complete validated dependency value covering runtime,
  HTTP, WebSocket, durable local storage, artifact handling, secrets, crypto,
  graph execution, and event delivery.
- `create` receives an explicit `Eio.Switch.t` lifetime token but no
  `Eio_unix.Stdenv.base`; transport, clock, sleep, and scheduling operations are
  supplied through the validated dependencies.
- The client exposes no `default_platform`, default transport, implicit native
  crypto, global runtime, or fallback dependency. Production and tests both
  construct explicit dependencies before calling the same `create`.
- The client implementation performs every host effect through the dependency
  values retained by that client instance. Direct calls to concrete Eio network
  adapters, Apple crypto stubs, and ambient filesystem functions are confined to
  explicitly constructed adapter implementations.
- `Engine` no longer imports or aliases `E2ee`, `Graph_key`, `Mirror`, `Pending`,
  `Platform_crypto`, sync `Protocol`, `Replay`, `Tx`, or `Tx_encoder`.
- The worker graph backend neither accepts nor returns raw WebSocket payloads.
  Wire decode/encode and pending submission state remain private to
  `logseq_sync`.
- A managed local mutation is durably recorded as pending before its projected
  result becomes visible. Duplicate mutation IDs, restart recovery, rebase, and
  blocked mutation behavior remain deterministic.
- Every managed graph mutation enters through `Logseq_sync.Api`; worker-owned
  mutation request and result types cross the boundary through type parameters.
  The managed path does not execute `Engine.execute` followed by a wake-only
  `notify_local_change`.
- An authoritative pull commits its database transaction and
  `Sync_checkpoint` atomically before the public cursor advances. Ownership
  revalidation, checksum mismatch pause, duplicate pull, accepted pending echo,
  and uncertain submission recovery preserve their current behavior.
- Managed graph mutation, pull, reconnect, foreground/background, graph switch,
  sign-out, and shutdown integration tests exercise only the public sync API.
- Sync implementation unit tests live under `logseq_sync`; redundant worker
  tests that existed only to reach private sync modules are deleted.
- No sync or worker test depends on ClojureScript, a Logseq CLI, a
  repository-external CLI, or code outside this repository.
- `dune build @all`, the retained package tests, public-source boundary checks,
  opam dependency validation, and `spec-dev-tool check --all` pass.

## Implementation evidence

- `logseq_sync/spec/api.mli` is the only handwritten public sync contract, and
  installed-package/source-boundary tests reject `Logseq_sync.Client`, physical
  implementation module names, private sublibraries, and worker-side include
  paths into `.logseq_sync_impl.objs`.
- `Logseq_sync.Api.create` accepts explicit validated capability values. Concrete
  Eio transport, Unix storage, artifact decoding, and Apple secret/crypto calls
  are confined to adapter constructors; the client core invokes the retained
  capabilities.
- The Bonsai service performs one explicit production composition and routes
  managed mutations through `Logseq_sync.Api.mutate`. `Engine` exposes only the
  normalized graph-backend operations and atomically commits authoritative
  database changes with `Sync_checkpoint` persistence.
- Sync-focused coverage now lives in `logseq_sync/test`. Sixteen public risk
  scenarios cover creation validation, offline restore, token fencing, shutdown,
  reconnect, authorization, remote contracts, pending recovery, replay,
  snapshots, E2EE, and transport policy without importing worker-private sync
  modules or external oracles.
- Fixture generation uses public storage constructors and a checked-in catalog
  template. Obsolete worker tests and the cross-runtime ClojureScript oracle are
  removed.
- `dune build @fmt`, `dune build @all`, `dune build @install`, and
  `dune runtest` pass. `logseq_sync.opam`, `logseq_db_worker.opam`, and
  `logseq_journal.opam` pass `opam lint`. A macOS debug native artifact built by
  `bonsai-flutter build-native` passes Mach-O and Apple complete-object
  verification.

## Consequences

- The package direction is enforced by both build metadata and source-boundary
  tests: sync can invoke worker behavior only through caller-supplied graph
  callbacks and has no compile-time worker dependency.
- Every executable and test must choose its runtime, transport, persistence,
  artifact, secrets, crypto, graph, and event capabilities before client
  creation. Missing production wiring fails during construction rather than at
  the first encrypted or network operation.
- `Logseq_db_worker.Engine` is no longer a second sync implementation. Wire
  compatibility, pending state, mirror lifecycle, encryption, and replay policy
  can change inside `logseq_sync` without exposing their private modules to the
  worker.
- The public cutover is intentionally breaking. `Logseq_sync.Client`, default
  platform selection, raw sync payload callbacks, wake-only managed mutation,
  and physical private-module imports have no compatibility path.
- Managed mutation visibility now depends on successful durable pending append,
  while authoritative cursor advancement depends on successful atomic database
  and checkpoint commit.

## Risks

- The graph backend becomes more structured because it must preserve local
  pending durability and authoritative database atomicity without leaking sync
  types. An underspecified two-phase API could make projected state visible
  before pending persistence or advance a cursor before the database commit.
- Moving managed mutation routing through the client changes a hot application
  path, not only startup composition. Serialization and reentrancy rules must be
  explicit so a backend callback cannot synchronously re-enter the client loop.
- Broad low-level filesystem callbacks would make the public API large and
  security-sensitive; overly domain-specific callbacks could instead freeze
  current file layouts. The storage ports need a narrow durability contract.
- Removing `default_platform` means every executable and test composition must
  provide crypto and secret dependencies. Missing production wiring should fail
  during creation rather than at first encrypted graph use.
- Abstracting Eio completely would increase adapter code and could obscure
  structured-concurrency guarantees. Retaining Eio types would make the public
  client runtime-specific. This scope decision must be explicit.
- The current dirty worktree contains an in-progress package extraction and API
  replacement. Implementation must preserve unrelated edits and should not try
  to keep the current friend path as an intermediate compatibility layer.
- Deleting implementation-coupled worker tests can reduce coverage if equivalent
  sync-owned unit or public integration coverage is not identified before each
  deletion.

## Questions

- None. The canonical module name, explicit dependency boundary, Eio lifetime,
  normalized graph backend, and managed mutation entry point were implemented on
  2026-08-28.
