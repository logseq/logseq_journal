# Core Effect Runner End To End Sync

## Problem

`logseq_sync` currently tests `Logseq_sync.Core` and
`Logseq_sync.Effect_runner` as separate contracts. `core_contract.ml` drives
reducer events directly and inspects the resulting `Run`, `Delegate`, and
`Publish` instructions. `runner_contract.ml` submits isolated runner effects and
asserts their asynchronous completions, cancellation, and graph-key behavior.
These tests prove each public boundary, but no test connects the two public
modules through a serialized host and completes one live synchronization cycle.

The production composition exists in
`logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml`:

```text
worker command or runner completion
  -> serialized Managed_coordinator mailbox
  -> Core.step
  -> ordered instruction list
       -> Publish: worker push
       -> Run: Effect_runner.submit
       -> Delegate: worker-owned Engine and durable storage operation
  -> completion event returns to the same mailbox
```

Current tests therefore do not prove that the ordered instructions from one
real `Core.step` trace can be interpreted by the real `Effect_runner` and the
worker-authority interpreter until the client reaches `Current`. They also do
not prove the complete local-to-remote-to-local data cycle: atomic local mutation
and outbox creation, WebSocket submission, server acknowledgement, authoritative
pull, atomic database/checkpoint/outbox commit, and durable restart.

This gap matters because a defect can satisfy both isolated contracts while
breaking their composition. Examples include a completion posted outside the
serialized mailbox, a missing token reply, a `Delegate` result emitted with the
wrong scope, a WebSocket send before the submitted outbox state is durable, an
acknowledgement that removes an outbox record before authoritative echo, or a
cursor update published before the worker commits the authoritative batch.

The previously rejected `Two Full Runtimes Through Sync Server` exploration is
not the proposed starting point. It was rejected because `logseq_sync` was then
a collection of tools without a complete client composition. The reducer,
effect runner, and worker-owned `Managed_coordinator` composition now exist. The
new test should exercise that shipped composition rather than introduce a new
`Logseq_sync.Runtime` or a test-only imitation of the interpreter.

## Proposal

### Add one production-composition E2E scenario

Add one integration scenario under `logseq_db_worker/test`, where the package
dependency direction permits a test to use `logseq_sync`, the worker
coordinator, `Engine`, and SQLite together. Drive the public
`Logseq_db_worker_bonsai_service` request and push interface so the scenario uses
the same `Managed_coordinator`, `Core.step`, `Effect_runner.submit`, worker-effect
interpreter, and engine mutation path as the application.

Do not place the scenario under `logseq_sync/test`: that suite must not acquire a
reverse dependency on `logseq_db_worker`. Do not copy the coordinator into test
support, expose its private state, manually call `Core.step` from the test body,
or manually manufacture `Runner_completed` events. All runner completions must
be produced by `Effect_runner` and re-enter through the production mailbox.

The scenario uses one encrypted graph, two concurrently live clients, and one
controlled remote server. The sender and receiver each run the shipped worker
service with independent application-support directories, Core values, effect
runners, engines, SQLite mirrors, key handles, tokens, and WSS connections. All
cross-client data passes through the controlled server. The test must not add or
retain a single-client echo scenario.

### Bootstrap two clients from missing mirrors

Create two empty isolated application-support directories without a mirror,
catalog cache, wrapped graph key, or durable outbox. The server publishes one
encrypted graph, a baseline at cursor `0`, E2EE user-key and encrypted graph-key
responses, snapshot metadata, and one bounded snapshot artifact. Both clients
must independently discover the graph, request password recovery, unlock and
save the wrapped graph key, download and activate the snapshot, attach their own
engine, and reach `Current` at cursor `0`.

Use deterministic authenticated test crypto through the public
`Effect_runner.secrets` and `Effect_runner.crypto` constructors. Each client has
an independent secrets adapter state and key-handle lifecycle while deriving the
same graph key from the controlled server fixtures. The controlled server must
never receive the password, raw private key, raw graph key, or protected
plaintext.

This larger cold-start path is selected because the requested test prioritizes
automation breadth. It proves that a fresh client can proceed from account
identity to usable encrypted mirror without pre-seeding client state, and then
participate in live two-client synchronization.

### Use a controlled HTTPS/WSS server

Run a bounded loopback server under the same supervised Eio test lifetime. It
implements only the deployed contracts required by the scenario:

- independently authenticated `GET /graphs` requests for sender and receiver;
- `GET /e2ee/user-keys` and `GET /e2ee/graphs/<graph-id>/aes-key`;
- baseline pull, snapshot metadata, and snapshot artifact download endpoints;
- WebSocket upgrade at `/sync/<graph-id>`;
- `hello`, `pull`, `tx/batch`, `tx/batch/ok`, `changed`, and `pull/ok` messages;
- one monotonic server cursor and one authoritative transaction ledger; and
- deterministic readiness and shutdown signals.

The server validates the bearer token but records only redacted authentication
facts. It parses the outer WebSocket protocol and transaction identity needed to
allocate the next cursor, while treating the encoded transaction value as
opaque. It captures received wire bytes so the test can assert that protected
plaintext and graph-key material never crossed the remote boundary.

`Effect_runner.transport` currently creates its TLS authenticator internally
through `Ca_certs_nss.authenticator`. Change
`logseq_sync/spec/effect_runner.mli` so transport construction receives a
narrowly scoped TLS authenticator dependency. The production dependency
constructor supplies the existing system trust store; the test supplies an
authenticator rooted only in a static test CA. This specification change is
explicitly approved for the E2E test. No insecure HTTP/WS mode, disabled
certificate verification, environment-wide trust mutation, compatibility
constructor, or fallback trust behavior is added.

### Drive the complete trace through public inputs

The scenario performs this ordered trace:

1. Start sender and receiver managed-sync worker services with distinct empty
   support directories, distinct identities and bearer tokens, the controlled
   server origin, independent test secrets, and test crypto.
2. Restore both local accounts and reconcile both authenticated identities.
3. Answer every emitted `Need_id_token` through the matching client's public
   `Provide_token` command; never inject a token directly into a core or runner,
   and prove that one client's token cannot authorize the other client.
4. Let each client independently fetch the catalog and select the same encrypted
   graph through public commands. Observe that both mirrors are absent.
5. Let each client fetch its E2EE material, reach the public
   `awaiting_e2ee_password` state, submit the password through
   `Submit_e2ee_password`, unlock and save its wrapped graph key, fetch baseline
   and snapshot metadata, download the artifact, activate its mirror, attach its
   engine, open its WSS connection, complete the opening pull, and reach
   `Current` at cursor `0`.
6. Submit one protected application mutation only through the sender's
   `Graph_request`, not through `Core.local_batch_input`, an Engine helper, or a
   raw WebSocket send in the test body.
7. Observe the sender worker atomically commit the projected mutation and queued
   outbox record, the sender core request a durable transition to `Submitted`,
   and only then the sender effect runner send one `tx/batch`.
8. Have the server allocate cursor `1`, respond to the sender with
   `tx/batch/ok`, broadcast `changed` to both WSS connections, and answer each
   client's independent pull with the same authoritative encoded transaction.
9. Observe both cores inspect and decrypt their own authoritative batches and
   both workers atomically apply data, checkpoint, projection, and outbox
   changes. Both clients must publish `Current` at cursor `1`; only the sender
   had an outbox record, and it becomes empty only after its authoritative echo.
10. Stop both workers, reopen each from its own application-support directory
    without reusing pre-shutdown core, runner, engine, key-handle, or server
    state, and verify the same protected plaintext, unprotected structural
    values, cursor, checksum, and empty outbox on both clients.

Use promises or condition variables for server readiness, token demand,
connection establishment, cursor advancement, state publication, and shutdown.
Every wait must have a bounded timeout with diagnostics naming the client phase,
server phase, last redacted message type, cursor, and durable outbox state. Do
not use polling sleeps as synchronization.

### Preserve focused tests and ownership boundaries

This scenario complements the pure reducer, runner contract, engine atomicity,
protocol, E2EE, and source-boundary tests. It does not replace focused negative
tests because an E2E failure is intentionally broader and slower to diagnose.

Production source remains the single composition path. Add only the approved TLS
authenticator dependency to the canonical effect-runner specification. If any
other public-specification issue blocks implementation, stop and report it
rather than widening the API. Remove any temporary or obsolete test path
introduced during development; do not keep parallel coordinators, insecure
transport modes, compatibility aliases, or fallback trust behavior.

## Decision

Accept the proposal. Add exactly one public-service E2E scenario with two
process-isolated live clients, because the shipped `Worker_runtime` owns one
process-wide service runtime. Keep all client lifecycle state independent while
sharing only the loopback server, and inject a test-rooted TLS authenticator
through the approved `Effect_runner` transport dependency.

## Alternatives considered

### Put a host loop in `logseq_sync/test`

A test-owned loop could call `Core.step`, submit every `Run` instruction, and
interpret every `Delegate` instruction with an in-memory database. This would
visibly combine `Core` and `Effect_runner`, but it would prove a host that ships
nowhere and would either duplicate worker authority or add a forbidden reverse
dependency. It is not selected.

### Test `Core` and `Effect_runner` while bypassing transport

The test could execute local-store and crypto runner effects while manually
constructing completions for catalog and WebSocket operations. This is
deterministic and requires no TLS server, but it leaves the most failure-prone
asynchronous seam untested and does not establish an end-to-end sync flow. It is
not selected.

### Use HTTP/WS or disable certificate verification in tests

An insecure loopback-only branch would simplify setup, but it would make the
test exercise behavior production forbids and create a permanent security-policy
fork. An explicit test trust root preserves HTTPS/WSS behavior and is preferred.

### Depend on a deployed Logseq service

A live service would avoid implementing a controlled protocol server, but it
would require external credentials and mutable remote state, make failures
non-hermetic, and prevent exact assertions about remote plaintext exposure and
message ordering. It is not suitable for the default test suite.

### Use one client and authoritative echo

A single encrypted client could submit a transaction and consume its own
authoritative echo. This proves much of the composition seam with less setup but
does not prove that remote change notification and pull deliver the mutation to
an independent client. It is excluded because the requested behavior is
specifically synchronization between two clients.

### Start from warm mirrors

Pre-seeding two mirrors, catalog selections, and wrapped graph keys would isolate
the live transport path and shorten the test. It is not selected because the
requested priority is greater automation breadth: both clients must bootstrap
from missing mirrors and perform password recovery through public inputs.

### Use Apple native crypto

The native path would prove platform cryptographic integration, but it would
make the scenario platform-specific and bring Keychain and signing concerns into
the portable worker suite. Deterministic authenticated test crypto proves the
public effect-runner composition and confidentiality boundary; existing native
contract tests continue to own Apple cryptographic correctness.

## Acceptance criteria

- Exactly one new scenario drives two concurrently live instances of the shipped
  managed-sync service through their public request/push interfaces. Both reach
  `Core.Current` after cold bootstrap and again after one authoritative
  transaction originating from the sender.
- The scenario uses the production `Managed_coordinator`, `Core.step`,
  `Effect_runner.submit`, worker-effect interpreter, `Engine`, durable outbox,
  SQLite storage, HTTP client, and WebSocket client. The test body does not drive
  private reducer events, runner completions, Engine commits, or raw transport
  messages.
- The scenario remains in `logseq_db_worker/test`; `logseq_sync/test` retains no
  direct or transitive dependency on `logseq_db_worker`, Bonsai, the application,
  or Flutter.
- Sender and receiver own distinct support directories, Core values, effect
  runners, engines, SQLite mirrors, secret-adapter state, key handles, tokens,
  and WSS connections. No mutable client lifecycle state is shared.
- Starting with no mirror, catalog cache, or wrapped graph key, each client
  independently completes catalog discovery, encrypted graph selection, E2EE
  user-key and graph-key retrieval, password recovery, snapshot download,
  snapshot activation, graph attachment, and opening WebSocket pull.
- The controlled server sees two independently authenticated catalog/bootstrap
  sequences, two WSS connections, exactly one sender `tx/batch`, and independent
  opening and post-change pulls. Unexpected methods, paths, message types,
  cross-client tokens, or duplicate transaction IDs fail the scenario.
- The submitted outbox record is durable before the first `tx/batch` byte is
  sent. `tx/batch/ok` alone does not remove it; removal occurs only after the
  authoritative echo is atomically applied.
- Server-captured requests, frames, logs, and diagnostics contain neither the
  protected plaintext nor raw graph-key bytes.
- Both authoritative local databases contain the exact protected plaintext and
  expected unprotected structural values after their independent pulls and again
  after both workers restart.
- The durable checkpoint advances from cursor `0` to `1`, stores the expected
  checksum, and never advances ahead of the authoritative database commit.
- The final durable outbox is empty on both clients, both public sync phases are
  `Current`, and each reopened worker obtains the same database, cursor,
  checksum, and outbox facts only from its own support directory.
- Token requests are answered only through matching opaque token requests. Test
  diagnostics, failures, and captured pushes do not expose bearer tokens,
  passwords, plaintext graph keys, or private-key material.
- All fibers, sockets, graph-key buffers, engines, and temporary files close on
  both success and assertion failure. The server observes the WSS close and no
  task survives the test switch.
- The scenario uses bounded event-driven waits with phase-specific diagnostics
  and contains no unbounded sleeps or timing-only assertions.
- Focused core, runner, engine, protocol, E2EE, source-boundary, and native crypto
  tests remain in place.
- `dune runtest logseq_sync/test`, the new focused worker E2E test,
  `dune runtest`, source-boundary validation, `git diff --check`, and
  `spec-dev-tool check --all` pass.

## Risks

- Adding an explicit TLS authenticator dependency changes the canonical
  `Effect_runner` specification. The type must remain a transport construction
  capability, not expose raw transport operations or an insecure flag.
- A loopback HTTPS/WSS server can accidentally encode client implementation
  assumptions. It should validate pinned deployed message shapes and keep its
  state independent from the client's core, outbox, and database values.
- The production worker service currently owns runtime creation, which may make
  server readiness, token replies, and state observation awkward. Test support
  must use the existing public worker protocol instead of exposing coordinator
  internals for convenience.
- Eio concurrency can make failures timing-sensitive. Bounded promises and one
  serialized event owner per client are required for deterministic ordering and
  cleanup.
- E2EE checksums do not by themselves prove protected plaintext restoration.
  The reopened database needs a direct plaintext assertion in addition to cursor
  and checksum checks.
- Static test CA key material is public test fixture data, not an application
  secret. It must be scoped to loopback test hosts and excluded from production
  defaults and packaging.
- Cold-bootstrapping two clients makes the scenario broad and slower than
  contract tests. Keep it as one automated happy-path integration case rather
  than moving focused negative branches into it; phase-specific timeout
  diagnostics are essential for attribution.

## Consequences

The worker test suite now exercises the complete encrypted cold-bootstrap and
two-client synchronization composition through HTTPS and WSS. Test execution
requires a static loopback CA and two supervised child processes, but it does
not require external credentials, network services, or mutable trust settings.
`Effect_runner.transport` now requires an explicit TLS authenticator, and the
production service constructs that dependency from the system trust store.

The live protocol also establishes a stricter Core invariant: opening a
WebSocket enters `Pulling`, sends the checkpoint pull, and reaches `Current`
only after the authoritative pull result is committed. Cursor notifications and
submission acknowledgements request a pull, while an already active pull
coalesces duplicate notifications. Queued local submissions therefore wait for
the opening pull and their durable outbox transition.

## Implementation outcome

Implemented on 2026-08-29.

- `test_managed_sync_e2e.ml` starts sender and receiver service processes with
  distinct support directories, identities, bearer tokens, secret adapters,
  mirrors, and WebSocket connections. Both cold-bootstrap the same encrypted
  graph through the public service interface.
- A supervised Piaf loopback server serves the pinned HTTPS/WSS contracts from
  a static test CA, validates each client's token, records redacted protocol
  facts, enforces one sender transaction, and verifies durable outbox ordering.
- The sender creates one allowlisted protected journal page through
  `Graph_request`. Both clients independently pull and commit its authoritative
  echo, stop cleanly, and reopen their own SQLite mirrors to verify plaintext,
  structural page kind, cursor, checksum, and empty outbox.
- `Effect_runner` accepts an abstract TLS authenticator dependency. Production
  dependencies retain system CA trust, while the E2E test trusts only its test
  root. HTTP and WSS clients explicitly negotiate HTTP/1.1 through ALPN.
- `Pure_core` performs an opening pull before publishing `Current`, converts
  authoritative cursor and acknowledgement messages into coalesced pulls, and
  preserves the durable submission ordering contract.
- Focused Core, runner, worker service, and CLI tests pass alongside
  `dune build @all`, `dune build @fmt`, `dune runtest`, source-boundary
  validation, `git diff --check`, and `spec-dev-tool check --all`.

## Questions

- Resolved: maximize automation breadth. Both clients start without mirrors and
  complete snapshot bootstrap plus password-based E2EE recovery before live
  synchronization.
- Resolved: modifying `logseq_sync/spec/effect_runner.mli` to inject a scoped TLS
  authenticator is explicitly authorized.
- Resolved: do not add a single-client E2E. The scenario must prove data
  synchronization from one live client to a second independent live client.
