# Move Sync Transport Ownership into `logseq_db_worker`

## Problem

The current foreground-sync implementation splits ownership across Dart, the
Bonsai application, and `logseq_db_worker`:

- Dart owns Amplify authentication, graph catalog HTTP, snapshot baseline and
  metadata parsing, artifact download and gzip decoding, HTTP pull and transaction
  capabilities, WebSocket lifetime, reconnect timers, and graph-runtime replacement.
- `app/application.ml` owns the foreground handshake and pull pump over versioned
  `LJP2` application-platform messages.
- `logseq_db_worker` owns upstream message decoding, transaction replay, checksums,
  durable sync metadata, pending intents, optimistic projection, E2EE value
  transformation, DataScript state, and SQLite persistence.

This boundary leaves protocol knowledge in Dart even though the OCaml worker is the
only component that can interpret graph state correctly. Catalog fields, snapshot
baseline rules, snapshot metadata, E2EE endpoint responses, reconnect decisions,
and transport outcomes are validated in a different language from cursor continuity,
transaction replay, pending rebase, and checksum state. The `LJP2` bridge also turns
raw WebSocket messages into a Dart-to-Bonsai-to-worker round trip before the worker
can act on them.

The desired architecture is for `logseq_db_worker` to own every non-Amplify sync
responsibility, including HTTP, WebSocket, snapshot download, graph selection state,
E2EE network orchestration, reconnect, and pending submission. Dart should retain
only Amplify session ownership, authentication UI, a narrow fresh-ID-token
capability, the Flutter renderer and host, and platform security primitives that
cannot be implemented safely or portably in the worker. Sync UI logic belongs to
the OCaml Bonsai application and is rendered through `bonsai-flutter`.

The current worker lifecycle blocks this move. The Bonsai service calls
`Engine.open_` during service initialization, and `Config.t` requires an already
resolved graph target. Catalog discovery and snapshot bootstrap happen before that
engine exists. Moving transport alone would therefore be insufficient: the service
must become a long-lived account-and-sync manager that can run without an open graph,
then create, replace, and close graph engines as its selected graph changes.

This decision would supersede the Dart transport ownership selected by
`docs/agent-guide/implemented/architecture/2026-08-21-login-sync-port.md`. It does
not change the selected upstream Logseq db-sync wire protocol, local-first pending
model, plaintext local E2EE mirror, mutation allowlist, or authoritative replay
rules.

## Proposal

### Ownership boundary

Retain the following responsibilities in Dart or native platform code:

- configure Amplify and render `Authenticator`;
- restore, refresh, and sign out the Cognito session;
- answer an explicit worker request with a fresh Cognito User Pool ID token;
- host the Flutter renderer and deliver user input and platform effects to the OCaml
  Bonsai application;
- obtain application lifecycle signals and application-support capabilities;
- perform Keychain operations and Apple cryptographic primitives behind a narrow
  native interface.

Move the following responsibilities into `logseq_db_worker`:

- authenticated `GET /graphs` and graph-catalog decoding;
- selected-graph and mirror-status persistence and offline-open policy;
- schema admission and graph selection transitions;
- account, catalog, graph-picker, bootstrap, E2EE prompt, progress, and sync UI logic
  in the OCaml Bonsai application, rendered by Flutter through `bonsai-flutter`;
- E2EE key endpoint requests and key-package protocol interpretation;
- snapshot baseline, metadata, artifact download, bounded gzip decoding, progress,
  staged import, validation, and atomic activation;
- HTTP pull and HTTP transaction submission;
- WebSocket TLS handshake, send and receive loops, ping/pong, close, cancellation,
  reconnect, handshake, pull, and pending submission;
- every upstream sync protocol decision and every graph-state transition;
- graph switching, sync cancellation, engine replacement, and local-cache deletion.

Dart must not parse db-sync JSON, construct db-sync URLs, inspect upstream message
types, carry WebSocket frames, or implement reconnect and pending-pump policy after
the cutover.

### Amplify and ID-token bridge

Amplify remains the session and credential owner. The worker must not receive a
refresh token, persist any token, refresh Cognito credentials, or reproduce Cognito
challenge flows.

When an authenticated operation needs a credential, the worker emits a typed push:

```text
NeedIdToken { challengeId, purpose }
```

where `purpose` is one of catalog discovery, snapshot bootstrap, E2EE key access,
HTTP pull, transaction submission, or WebSocket connect. Dart obtains a fresh ID
token from Amplify and sends a bounded response:

```text
ProvideIdToken { challengeId, token }
```

The worker correlates the response with one pending challenge, rejects duplicate,
late, wrong-user, wrong-generation, or unsolicited responses, and uses the token
only for the current request or WebSocket handshake. Tokens must not enter
`Config.t`, application metadata, graph metadata, `sync_meta`, pending intents,
diagnostics, errors, or logs.

An OCaml string cannot provide a reliable zeroization guarantee. This design can
guarantee bounded lifetime, no intentional persistence, and no diagnostic exposure,
but it cannot guarantee that token bytes disappear immediately from process memory.
The product accepts this transient OCaml-memory exposure so the worker can own the
raw authenticated HTTP and WebSocket handshakes.

### Long-lived service lifecycle

Replace the graph-bound service state with an explicit account-and-graph state
machine. The exact public types remain to be designed, but invalid lifecycle
combinations should be unrepresentable and should cover at least:

```text
SignedOut
AwaitingToken
LoadingCatalog
CatalogReady
AwaitingSelection
Bootstrapping
OpeningGraph
GraphOpen
SyncPaused
StoppingGraph
Failed
```

Use one long-lived production worker rather than separate bootstrap and graph-bound
workers. The service starts without calling `Engine.open_`. After an authenticated
catalog is available and a graph is selected, it resolves or bootstraps the mirror
and creates an `Engine.t`. Graph switching closes transport and the current engine
before opening the next graph. Sign-out cancels authenticated work, closes the graph
engine, clears in-memory graph keys and tokens, retains the selected graph and local
mirror according to product policy, and returns to `SignedOut`.

`Engine` remains the owner of one open graph, DataScript state, SQLite,
authoritative replay, pending projection, and typed graph requests. A new manager
module owns account, network, bootstrap, and engine lifetime rather than adding
those responsibilities directly to `engine.ml`.

### Suggested OCaml module boundaries

Introduce focused modules with public `.mli` contracts:

- `Sync_manager`: account, catalog, bootstrap, transport, and engine lifecycle;
- `Sync_auth`: token challenges, user and generation correlation, and secret-safe
  errors;
- `Sync_http`: HTTPS execution, redirects, response bounds, cancellation, and
  authenticated request construction;
- `Sync_websocket`: WSS handshake, bounded frames, send/receive loops, close,
  ping/pong, and reconnect inputs;
- `Sync_catalog`: `/graphs` decoding, validation, cache merge, and selected-graph
  state;
- `Sync_bootstrap`: baseline, snapshot metadata, artifact download, gzip decoding,
  progress, and mirror activation;
- `Sync_e2ee_session`: E2EE endpoint contracts and unlock state while delegating
  protected platform operations;
- the existing `Sync_protocol`, `Sync_replay`, `Sync_pending`, `Sync_mirror`,
  `Sync_snapshot`, `Sync_checksum`, `Sync_tx`, and `Sync_tx_encoder` retain their
  graph and wire responsibilities.

Module names remain implementation-level choices. The user explicitly authorizes
the dependency and Dune changes required for an Eio-compatible HTTP, TLS, and
WebSocket stack. The implementation must still not modify any OCaml file under
`spec/`, or any `.mli` under `spec/`, unless separately requested as required by
repository instructions.

### HTTP ownership

The worker constructs endpoint paths, methods, query parameters, headers other than
platform-owned credentials, and bodies. It applies redirect policy, response size
bounds, content-type rules, timeout and cancellation policy, and response decoding.
It requests a fresh ID token immediately before each authenticated request.

Snapshot artifacts remain file-backed and bounded. The worker downloads to a
private staging path below its application-support root, reports raw entity-byte
progress, peels at most two gzip layers by content signature, imports only the final
framed stream, and removes every temporary on cancellation or failure. Snapshot
baseline checksum non-association remains an OCaml protocol decision: the baseline
`t` seeds the cursor, while the imported mirror computes and persists its own
checksum.

### WebSocket ownership

The worker requests a fresh token, establishes
`wss://<base>/sync/<graph-id>` with the bearer header, and owns the connection until
graph switch, sign-out, shutdown, or transport failure. After open it sends upstream
`hello` and `pull` directly through `Sync_protocol`; received frames feed the same
decoder and replay path without an `LJP2` hop.

Reconnect is an OCaml state transition. Each attempt obtains a fresh token, performs
a new handshake, and pulls from the durable `applied_server_t`. Connection and graph
generations fence late frames. A `changed` message remains only a pull hint.
`tx/batch/ok` marks submitted intents accepted, and authoritative pull replay remains
the only action that updates the mirror or removes confirmed pending intents.

The first implementation scope is foreground sync parity on iOS and macOS. It does
not add bounded iOS background HTTP pull; background replay remains a later decision.

### Concurrency and engine serialization

The existing Bonsai worker service uses Eio and serial request handling. Network
waits must not occupy the serial graph handler, and network fibers must never call
`Engine.execute` or `Storage_session` concurrently.

Run HTTP, WebSocket receive, send, reconnect, and timeout work in supervised Eio
fibers. Convert their outcomes into typed internal events and deliver those events
to one serialized manager/engine loop. All DataScript and SQLite operations remain
serialized. Cancellation must close network resources and prevent an obsolete
fiber from enqueueing an event for a new account, graph, engine, or connection
generation.

Do not mix an Async network event loop into the Eio worker merely because Async and
Cohttp Async appear transitively in the lockfile. Select and explicitly depend on a
network stack that integrates with the worker's runtime and can be built and linked
for both iOS and macOS.

### UI and service protocol

Replace transport-oriented `LJP2` messages with typed worker commands and pushes for
user intent and observable state. The protocol should cover at least:

- authenticated user available or signed out;
- ID-token response or token acquisition failure;
- catalog refresh and graph selection;
- E2EE password or platform-key operation response;
- bootstrap and download progress;
- active graph and sync status;
- local-cache inspection, confirmed deletion, and redownload;
- recoverable and terminal account, network, schema, E2EE, and graph errors.

The OCaml Bonsai application owns account, graph-picker, bootstrap, progress, and
sync UI logic. `bonsai-flutter` renders the resulting widget tree and returns user
input to OCaml. Dart retains the outer Amplify `Authenticator` host but must not own
an independent account-selection or sync state machine.

Apple Keychain and CryptoKit remain native capabilities. All E2EE endpoint requests,
key-package interpretation, unlock orchestration, graph-key lifetime, and sync value
transformation move to OCaml. Native code receives only bounded operation inputs and
returns typed outcomes without owning E2EE product state.

### Removal of obsolete paths

Do not preserve the current Dart transport as a fallback or compatibility layer.
When an endpoint or lifecycle path cuts over to the worker, remove the corresponding
production Dart implementation and its bridge messages. The completed migration
removes at least:

- `JournalSyncNetwork`, `JournalSyncSocket`, and `JournalSyncTransport`;
- Dart graph-catalog and snapshot protocol parsers;
- Dart snapshot baseline and artifact transport orchestration;
- Dart WebSocket open, send, receive, reconnect, and generation state;
- Dart E2EE endpoint requests;
- sync-specific `LJP2` request and event tags;
- `Journal_graph_request.Sync_receive`;
- the foreground transport state machine in `app/application.ml`;
- graph-specific runtime replacement whose only purpose is selecting a different
  sync transport and startup target.

Tests may use explicit in-memory OCaml network and auth capabilities. They must not
retain a production Dart transport implementation under a test or developer flag.

## Decision

Implement one long-lived `logseq_db_worker` service as the owner of account-aware
graph lifecycle and every db-sync transport operation. The service starts without
an `Engine.t`; `Sync_manager` serializes authentication challenges, catalog state,
graph selection, bootstrap, engine replacement, foreground transport, reconnect,
pending submission, sign-out, and local-cache reset. Generation-scoped supervised
Eio fibers perform network work and return typed events to that serialized owner.

Use OCaml HTTP/TLS and WebSocket clients for catalog, E2EE, snapshot, pull,
submission, and live sync. Require a fresh, purpose-scoped Amplify ID token for each
authenticated operation or connection, and retain no token in durable state or
diagnostics. Keep the snapshot path file-backed and bounded, validate media types
and gzip depth, and activate a fully validated staged mirror atomically.

Keep Amplify session handling and `Authenticator` in Dart, and keep Keychain and
CryptoKit operations in narrow native capabilities. Move account, graph-picker,
bootstrap, E2EE, progress, reset-confirmation, and sync status state into the OCaml
Bonsai application. Remove the production Dart db-sync transport, parsers, reducer,
and sync-specific `LJP2` bridge rather than retaining a fallback.

Target foreground parity on macOS and iOS. Do not add an iOS background replay
path. Preserve the existing authoritative replay, durable pending, cursor,
checksum, plaintext-local E2EE mirror, and mutation-allowlist semantics behind the
new ownership boundary.

## Alternatives considered

### Keep Dart as the transport capability provider

This is the current architecture. It keeps platform I/O simple but retains catalog,
snapshot, E2EE, reconnect, and WebSocket knowledge outside the component that owns
protocol and graph consistency. It does not meet the requested ownership boundary.

### Move protocol parsing to OCaml but leave HTTP and WebSocket in Dart

This would reduce duplicated validation while preserving `LJP2` raw-message hops,
Dart reconnect policy, pre-runtime bootstrap ownership, and split lifecycle state.
It is a smaller change but does not make the worker the sync owner.

### Move Amplify into OCaml

Amplify has no OCaml frontend SDK, and reimplementing Cognito challenge flows,
session refresh, Authenticator UI, callbacks, and secure session storage would add a
large security-sensitive platform subsystem. Calling Amplify Swift through FFI
would still leave Amplify native and would add another bridge. Amplify therefore
remains the explicit exception to OCaml ownership.

### Keep ID tokens entirely outside OCaml through an authenticated transport proxy

Dart or native code could inject authorization headers while OCaml supplies request
descriptions. That preserves a strict credential boundary, but the proxy would still
own HTTP/WebSocket handshakes and would contradict the requirement that the worker
own network requests. This alternative remains relevant if transient token exposure
in OCaml is unacceptable.

### Run a temporary bootstrap worker and replace it with a graph worker

A pre-graph worker could fetch the catalog and snapshot, exit, and then launch the
existing graph-bound worker. It avoids changing `Engine` ownership but duplicates
lifecycle, authentication challenges, cancellation, progress, and network setup
across two services. A single long-lived manager with an optional engine provides a
clearer owner for graph switching and reconnect.

## Acceptance criteria

- Production Dart code uses Amplify for authentication but contains no db-sync
  endpoint, URL construction, response parser, WebSocket, reconnect, snapshot
  transport, E2EE endpoint request, or pending-pump implementation.
- `logseq_db_worker` starts without an open graph, requests authentication
  capabilities, fetches and validates the authorized catalog, accepts graph
  selection, and opens an existing mirror or atomically bootstraps a missing one.
- Account, graph-picker, bootstrap, progress, E2EE prompt, and sync UI logic is owned
  by the OCaml Bonsai application and rendered by Flutter through `bonsai-flutter`;
  Dart retains no parallel selection or sync reducer.
- Every HTTP request and WebSocket connection is initiated and owned by OCaml; each
  authenticated operation obtains a fresh Amplify ID token through the bounded auth
  challenge protocol.
- No ID token or other Cognito credential is persisted, logged, returned in errors,
  included in startup or graph metadata, or retained after its operation or
  connection generation becomes obsolete.
- Snapshot download is file-backed, bounded, cancellable, progress-reporting, and
  accepts the deployed one- and two-layer gzip representations while rejecting more
  than two layers without residue.
- Foreground WebSocket connects, sends `hello`, pulls from durable server `t`,
  consumes `changed`, replays transactions, pumps pending batches, handles every
  rejection form, reconnects with a fresh token, and rejects late frames by
  generation entirely inside the worker.
- Network fibers never access the graph engine, DataScript, `Storage_session`, or
  SQLite concurrently; graph operations and sync events are processed by one
  serialized owner.
- Graph switching and sign-out close the old WebSocket, cancel retries and HTTP work,
  reject late token and network completions, close the old engine, and clear
  in-memory graph keys before another graph or account can open.
- Plain and encrypted real db-sync graphs pass equivalent macOS and physical-iPhone
  foreground bootstrap, replay, mutation, reconnect, restart, offline-open,
  sign-out, graph-switch, and local-cache-reset tests.
- The first implementation introduces no iOS background replay path.
- HTTP pull uses the same OCaml decoder, replay, cursor, checksum, pending-rebase,
  and invalidation state machine as WebSocket pull.
- The old Dart transport and sync-specific `LJP2` production paths are deleted; no
  fallback or migration layer remains.

## Risks

- A bearer ID token must transiently enter OCaml memory if OCaml owns the raw HTTP
  and WebSocket handshake. OCaml strings cannot promise reliable zeroization.
- The current service is graph-bound. Making it long-lived changes startup, account,
  graph selection, error presentation, graph switching, and shutdown ownership at
  once.
- An incorrect fiber boundary could permit concurrent access to `Engine`, DataScript,
  SQLite, pending storage, or graph keys.
- A native OCaml HTTP, TLS, and WebSocket stack must compile, link, and validate
  certificates correctly on both iOS and macOS. Platform proxy, trust-store, DNS,
  cancellation, and app lifecycle behavior may differ from Dart `HttpClient`.
- Moving artifact download into the native worker expands its filesystem and network
  attack surface. Redirects, paths, symlinks, file permissions, size bounds, gzip
  layers, cleanup, and cancellation must remain fail-closed.
- Removing graph-specific runtime replacement may expose assumptions in the Bonsai
  UI and worker protocol that graph identity never changes during one service
  session.
- A serialized engine queue can be starved by large replay batches unless network
  and replay work use explicit bounds and yield points without weakening atomicity.
- Existing Flutter integration tests mock Dart transport objects. They must be
  replaced with worker-level network capability fixtures and compiled-runtime tests.

## Consequences

- Sync correctness and transport lifecycle now share one serialized OCaml owner,
  eliminating the cross-language protocol round trip but increasing the native
  worker's networking, cancellation, and filesystem responsibilities.
- Dart retains a deliberately narrow security boundary: Amplify owns sessions and
  issues fresh tokens, while OCaml transiently holds each token for one request or
  WebSocket generation without a reliable zeroization guarantee.
- The same long-lived service now owns catalog state and optional graph-engine
  state, so graph switching and account replacement invalidate network work and
  close the old engine rather than replacing the Flutter runtime.
- Snapshot download, gzip handling, E2EE orchestration, reconnect, HTTP fallback,
  and pending submission are built and tested as native iOS and macOS code. Future
  transport changes must preserve both Apple targets and the serialized-engine
  boundary.
- The Dart transport and sync-specific application bridge no longer exist as a
  fallback. Failures remain visible in the OCaml-owned UI and must be repaired in
  the worker-owned path.
- Background iOS replay remains outside this decision; foreground lifecycle resume
  is the only automatic resumption mechanism introduced here.

## Questions

None. The user accepted transient ID-token presence in OCaml memory, selected one
long-lived worker, assigned UI logic to OCaml Bonsai with Flutter rendering, limited
the first implementation to iOS and macOS foreground sync, retained Keychain and
CryptoKit as native capabilities, and authorized the required Eio-compatible network
dependencies and Dune changes.
