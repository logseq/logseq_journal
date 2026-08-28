# Two Full Runtimes Through Sync Server

## Problem

The current `logseq_sync` E2EE roundtrip scenario does not run two sync runtimes.
It creates two independent SQLite-backed storage sessions, but the sender calls
`Tx_encoder` directly, a test helper copies the encoded transaction from
`tx/batch` into `pull/ok`, and the receiver calls `Replay.apply_pull` directly.
That proves the package data path, confidentiality boundary, and durable replay,
but it does not prove runtime orchestration or server communication.

The requested replacement must remain wholly owned by the `logseq_sync` package.
`logseq_sync/test` must not import or link `logseq_db_worker`,
`logseq_db_worker_bonsai`, `Worker_runtime`, application code, or Flutter code.
The existing lower-package dependency direction remains authoritative: an upper
worker may depend on sync, but sync tests must never depend back on the worker.

This package-only constraint exposes a product boundary gap. `logseq_sync`
currently publishes protocol, `Manager`, Eio HTTP/WebSocket clients, pending
storage, transaction encoding, replay, mirror, and graph-key components, but it
does not publish a startable `Runtime`. The production action interpreter that
combines `Manager`, transport, graph engine lifetime, pending submission, and
replay currently lives in `logseq_db_worker_bonsai_service`. Consequently, a test
can compose existing sync modules into a test-owned harness, but calling that
harness a “full runtime” would not prove any package-owned production runtime.

The desired observable behavior is:

1. start two independent package-owned sync runtimes, sender and receiver;
2. authenticate both runtimes against one controlled server;
3. have both runtimes open the same encrypted graph and establish separate
   WebSocket connections;
4. submit a protected mutation through the sender runtime rather than call the
   transaction encoder or WebSocket client from the test body;
5. let the server accept the batch, allocate the next server cursor, acknowledge
   the sender, and notify both connections;
6. let each runtime independently request and apply the authoritative pull;
7. prove that the server never receives protected plaintext;
8. prove that the receiver decrypts and durably stores the mutation; and
9. stop and reopen the receiver runtime to prove durable cursor, checksum, and
   graph state.

Direct test calls from encoded sender bytes to receiver replay are forbidden in
the replacement. All cross-client data must pass through the server's connection
state and the same public runtime entry points used by each client.

## Proposal

The candidate design is to introduce a package-owned `Logseq_sync.Runtime` rather
than grow a test-only imitation of the interpreter that currently lives above the
package. The runtime should compose existing modules and expose a small lifecycle
API suitable for both production adapters and tests:

- create/start with an application-support root, managed-sync origin, user
  identity, token provider, crypto capability, graph-key capability, and Eio
  environment;
- restore/select/open one graph through `Manager` actions;
- own one `Storage_session`, durable `Sync_checkpoint`, `Pending` store, and
  zeroizable `Graph_key.t` while the graph is open;
- own HTTP and WebSocket connection fibers, dispatch `Manager` events serially,
  and fence late work by account, graph, and connection generation;
- accept a package-level outgoing transaction request, durably queue it before
  sending, and expose observable runtime state without exposing credentials or
  plaintext graph keys;
- decode every server frame through `Protocol`, apply pulls through `Replay`, and
  clear accepted pending entries only after authoritative echo; and
- close network, storage, pending, and key state deterministically.

The runtime must not import mutation planners or graph-query APIs from
`logseq_db_worker`. Its outgoing boundary should accept sync-owned data: stable
mutation identity, normalized `Datascript.tx_op` values, and an upstream
`outliner_op`, or a narrower package-owned submission type selected during design.
The test fixture can construct this request directly. Application mutation
planning remains outside the `logseq_sync` package.

### Controlled loopback server

Run one test server under the same supervised Eio switch as the two runtime
instances. It must use real loopback sockets and implement the minimum deployed
contract needed by a warm local graph:

- authenticated `GET /graphs` for sender and receiver identities;
- WebSocket upgrade at `/sync/<graph-id>`;
- `hello`, `pull`, `tx/batch`, `tx/batch/ok`, `changed`, and `pull/ok` messages;
- one authoritative ordered transaction ledger with duplicate transaction-ID
  rejection and monotonic server `t`; and
- bounded request/frame handling and deterministic shutdown.

The server treats the encoded protected value as opaque and records every received
wire payload so the test can assert that protected plaintext never crossed either
connection. It may decode only the outer protocol and the structural transaction
fields needed to compute the E2EE checksum; it must not possess a graph key or call
the receiver's decryption callback.

Use actual HTTPS and WSS over loopback with a test certificate authority. Do not
weaken `Http.validate_base_url`, permit plaintext schemes, disable certificate
verification, or add a production insecure flag. Instead, make the TLS
authenticator an explicit transport dependency: production continues to use
`Ca_certs_nss.authenticator`, while this scenario supplies an authenticator rooted
only in the static test CA. The server certificate and private key are non-secret
test fixtures restricted to `localhost`/loopback.

### Two independent runtime instances

Both runtimes run concurrently inside one `Eio_main.run` but own separate:

- application-support roots and SQLite files;
- `Manager.t` values and generation counters;
- HTTP/WebSocket connections and bearer tokens;
- pending stores and transaction IDs;
- `Storage_session` values; and
- `Graph_key.t` values constructed from equal 32-byte graph-key material.

Running them in one process avoids the global single-session restriction of the
upper `Worker_runtime`, which is outside this test's scope. Independence is proved
by distinct paths, object lifetimes, connection IDs, and runtime state rather than
by depending on that upper runtime or spawning application processes.

Preseed both clients with the same encrypted-graph mirror, catalog selection,
wrapped graph key, and active checkpoint. Each runtime still performs its own
authentication, catalog reconciliation, local graph open, and WSS connection. The
scenario intentionally avoids snapshot bootstrap and password-based private-key
recovery so a failure identifies the live two-client synchronization path. Those
flows remain covered by their focused package tests.

After both runtimes report graph-open and reconciled state, submit one mutation to
the sender. The server must observe one `tx/batch`, return `tx/batch/ok`, broadcast
`changed`, and answer each runtime's pull from its own durable cursor. Acceptance
requires both runtimes to reach the same server `t` and E2EE checksum; the sender
must remove the pending entry only after its authoritative echo, and the receiver
must expose the decrypted title only after replay. Restart the receiver from its
own application-support root and verify the same state without contacting or
reading the sender.

When the new scenario passes, delete the current direct `server_echo` roundtrip
path instead of retaining it as a compatibility or fallback scenario. Focused
unit scenarios for `Tx_encoder`, `Protocol`, `Replay`, graph-key clearing, and
tamper rejection remain because they test narrower failure contracts.

## Questions

- Does “full runtime” authorize introducing a production
  `Logseq_sync.Runtime`/action interpreter inside the package, or should the test
  use a test-only runtime harness despite not exercising a shipped interpreter?
- Must the controlled server use real loopback HTTPS/WSS with an injected test CA
  as proposed, or is a real socket server with an injected non-TLS test transport
  sufficient?
- Should both clients start from preseeded local mirrors and test authentication,
  catalog reconciliation, WSS, submission, pull, replay, and restart, or must this
  single scenario also bootstrap both mirrors and recover their E2EE private-key
  packages from the server?

## Acceptance criteria

- The scenario and every helper it imports remain under `logseq_sync/test` or a
  `logseq_sync` production library; Dune dependency inspection shows no direct or
  transitive `logseq_db_worker`, Bonsai worker, app, Flutter, or `Worker_runtime`
  dependency.
- Two concurrently live runtime instances own independent manager, transport,
  pending, storage, checkpoint, and graph-key state.
- The test submits the mutation only through the sender runtime's public API. The
  test body never passes encoded transaction bytes, server messages, storage
  sessions, or replay callbacks from sender to receiver.
- All cross-client data traverses distinct real loopback TLS connections and a
  controlled server's HTTP/WSS protocol implementation.
- Both clients authenticate independently; the server rejects a missing, wrong,
  or cross-client bearer token without exposing the token in diagnostics.
- The sender sends exactly one durable transaction ID, receives acknowledgement,
  retains its pending entry until authoritative echo, then removes it.
- The server allocates one next cursor, records one authoritative transaction,
  broadcasts a change hint, and answers independent pulls from sender and
  receiver.
- The server's captured HTTP bodies, WebSocket frames, errors, and diagnostics do
  not contain the protected plaintext or plaintext graph key.
- The receiver reaches the server cursor and E2EE checksum through its own
  `Manager`/transport/replay path and restores the exact protected plaintext plus
  an unprotected structural value.
- After receiver shutdown and reopen from its own application-support root, the
  same plaintext, cursor, checksum, and empty pending state are present without
  reading sender state.
- Both runtimes clear graph keys and close storage and sockets on normal completion
  and assertion failure; the server observes both connection closures.
- The direct `server_echo` roundtrip helper is deleted after replacement; no
  compatibility alias or second pseudo-runtime path remains.
- The scenario uses bounded deterministic waits or promises, never unbounded
  sleeps, and emits enough phase diagnostics to identify sender, receiver, or
  server timeout.
- `dune runtest logseq_sync/test`, package source-boundary validation, and
  `spec-dev-tool check --all` pass.

## Risks

- Introducing a production `Logseq_sync.Runtime` is an architectural change, not
  only a test edit. The public ownership boundary and future upper-worker adapter
  must be agreed before implementation.
- Moving runtime composition into the package could duplicate the current worker
  interpreter if the upper implementation is left intact. The eventual production
  cutover must remove duplicated ownership rather than preserve both paths.
- A static test CA private key is suitable only as a clearly named test fixture. It
  must never be loaded by production defaults, packaged as an application secret,
  or accepted for non-loopback hosts.
- Concurrent Eio fibers can make failures timing-sensitive. The server and runtime
  need explicit readiness, cursor, pending, and shutdown promises instead of
  polling sleeps.
- E2EE checksums exclude protected title/name plaintext. The receiver needs an
  explicit plaintext database assertion in addition to checksum convergence.
- Preseeding mirrors omits snapshot bootstrap, password unlock, and first-device
  key setup from this scenario. Those boundaries remain separate and must not be
  claimed as part of the two-client live-sync result.
- A minimal server can accidentally encode client assumptions instead of the
  deployed contract. Its fixtures and state transitions should reuse pinned
  protocol shapes, while remaining independent of client runtime state.
- Running two instances in one process cannot prove process-level isolation. It
  does prove independent runtime values and network connections, provided the
  runtime introduces no mutable global lifecycle state.

## Alternatives considered

### Keep a test-only runtime harness

The test could define a `runtime` record under `logseq_sync/test` and interpret
`Manager` actions using the package's public modules. This avoids a production API
change, but it proves an interpreter that ships nowhere. The current test already
has this weakness at a smaller scale. It is not recommended if “full runtime” is
intended literally.

### Use `logseq_db_worker_bonsai_service` as the runtime

That service is the current production composition and would give the closest app
behavior. It would also create a forbidden reverse dependency from
`logseq_sync/test` to an upper package and would require separate processes because
`Worker_runtime` supports only one attached session. This alternative is excluded
by the explicit package-only test scope.

### Keep direct in-process server echo

The existing helper is deterministic and fast, but it bypasses connection
lifetime, authorization, `Manager` action dispatch, submission acknowledgement,
changed notification, independent pull requests, and runtime shutdown. It cannot
satisfy the revised goal.

### Use an injected in-memory transport

An in-memory server capability would exercise runtime state transitions without
socket or TLS complexity. It would not prove that two runtimes can communicate
through the package's HTTP/WSS implementations, so serialization, handshake,
framing, and connection-lifetime gaps could remain invisible.

### Permit HTTP/WS for loopback tests

Allowing insecure schemes only in tests is simpler than supplying a test trust
root, but it creates a security-policy branch in production modules and weakens
the assertion that all managed-sync traffic uses TLS. A scoped TLS authenticator
dependency preserves the production policy.

### Bootstrap both clients from the server

Serving baseline, snapshot metadata, a framed snapshot artifact, E2EE user keys,
and wrapped graph keys would exercise more startup behavior. It would make one
scenario responsible for nearly every sync subsystem and obscure failures in the
live transaction roundtrip. The candidate design starts from two durable local
mirrors and tests online reconciliation plus live sync.

### Run each package runtime in a subprocess

Separate processes give stronger isolation and catch global state, but add process
coordination, port publication, crash cleanup, and platform variance. If the new
package runtime has no singleton state, two instances under one Eio switch provide
the required independent lifecycle while remaining deterministic. Subprocesses
remain an escalation if in-process isolation reveals global-state coupling.

## Rejection reason

logseq_sync must first be redesigned as a complete sync client library rather than a collection of sync tools.
