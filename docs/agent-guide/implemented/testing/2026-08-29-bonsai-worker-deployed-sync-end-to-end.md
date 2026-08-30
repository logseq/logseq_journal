# Bonsai Worker Deployed Sync End To End

## Problem

`logseq_db_worker.bonsai` owns the shipped composition of the worker protocol,
managed-sync coordinator, pure sync core, effect runner, Engine, SQLite mirror,
and durable outbox. The current
`logseq_db_worker/test/test_managed_sync_e2e.ml` exercises that composition with
two process-isolated clients and a controlled loopback HTTPS/WSS server.

The controlled server proves locally defined protocol and persistence behavior,
but it cannot prove compatibility with the deployed managed-sync service. A
change to deployed authentication, catalog responses, E2EE envelopes, snapshot
artifacts, WebSocket messages, or transaction handling can break the worker
while the current E2E remains green.

The required coverage is one end-to-end flow through the public
`Logseq_db_worker_bonsai_service` interface and the real service at
`https://api.logseq.io`:

```text
account restore and authentication
  -> catalog discovery and graph selection
  -> E2EE unlock and snapshot bootstrap
  -> opening pull and Current
  -> Graph_request mutation and durable outbox
  -> deployed submission and authoritative pull
  -> independent clean worker recovery
  -> remote cleanup
```

This test does not mount `Application.app`, render UI, use
`Bonsai_flutter_test.Handle`, or cover Dart, Flutter, Amplify, MethodChannel, or
native application lifecycle. Those layers are outside this decision.

The deployed test should replace the current loopback E2E rather than remain as
a parallel compatibility path. This deliberately trades deterministic protocol
simulation for verification of the real service contract. Focused Core, runner,
protocol, E2EE, Engine, and storage tests remain responsible for deterministic
failure and invariant coverage.

## Proposal

### Replace the loopback scenario with one deployed-service scenario

Replace `test_managed_sync_e2e.ml` with one macOS-only online E2E under
`logseq_db_worker/test`. Start the real
`Logseq_db_worker_bonsai_service` through `Worker_runtime` with:

```text
Managed_sync { base_url = "https://api.logseq.io" }
```

Use the production service composition and system TLS verification. Do not copy
the coordinator, call `Core.step` from the test, manufacture runner completions,
bypass Engine mutations, introduce a test transport, or inspect private sync
state.

Before launching the standalone OCaml worker executable, compile
`flutter/JournalE2EECrypto.swift` as a temporary macOS dynamic library and
inject it into a supervised child process. This supplies the same
`logseq_journal_crypto_json` implementation linked into the production app;
the fallback C stub in a standalone OCaml executable cannot perform platform
crypto. The DEBUG test host scopes secret persistence to a fresh disposable
file-based macOS Keychain because an ad-hoc executable has no Data Protection
Keychain entitlement. Remove the temporary library and Keychain after the child
exits. Do not enable the Swift provider's debug memory stores, access the ambient
Keychain, or replace crypto with a fake.

Drive the service only through its public inputs:

- `Restore_local_account` and `Reconcile_authenticated_user`;
- `Provide_token` in response to the matching `Need_id_token` push;
- `Select_graph` after the configured graph appears in public catalog state;
- `Submit_e2ee_password` when public state requests it; and
- `Graph_request` for all graph reads and mutations.

Observe progress through public responses and pushes plus durable storage facts
at safe lifecycle boundaries. While a worker owns a database, use public state;
inspect SQLite checkpoint and outbox state only after worker shutdown unless an
existing storage API explicitly permits concurrent observation.

Remove the loopback server implementation, its child-client protocol used only
by that server, the static test CA/server certificate/private-key fixtures, and
any dependencies used only by the deleted scenario. Keep a fixture or helper
only when another current test imports it. Do not preserve a disabled loopback
mode, compatibility alias, fallback URL, or second E2E executable.

### Use a dedicated named encrypted graph

Provision one account used only by this destructive E2E lane. Configure the
exact name of one encrypted graph so catalog discovery identifies the target
without restricting the account from containing other graphs. The only manually
supplied secret values are:

- the test account identifier;
- the test account password; and
- the graph E2EE password.

The graph name is manually supplied non-secret configuration. Catalog selection
must find exactly one graph whose name is an exact match, and that graph must be
encrypted. Fail before mutation if the named graph is absent, duplicated, or
unencrypted.

An automated credential helper signs in with those credentials through the
deployed authentication service and obtains a fresh Cognito User Pool ID token
for the run. The worker harness returns that token only for its matching opaque
token challenge and rejects stale or mismatched challenges. When public worker
state requests E2EE recovery, the harness submits the independently configured
graph E2EE password through `Submit_e2ee_password`.

Read the test configuration only from these environment variables:

- `LOGSEQ_DB_WORKER_E2E_USERNAME`;
- `LOGSEQ_DB_WORKER_E2E_PASSWORD`;
- `LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD`; and
- `LOGSEQ_DB_WORKER_E2E_GRAPH_NAME`.

Treat any missing, empty, NUL-containing, or unreasonably large value as invalid
and fail before authentication or worker startup. Never place a supplied secret
or the resulting token in repository files, Dune actions, process arguments,
captured output, assertion messages, support fixtures, or retained artifacts.
The graph name may appear only where needed for catalog matching and must not
appear in diagnostics. Child worker processes may inherit these variables from
the supervised parent, but must not copy them into arguments or emit them.

The graph must not be personal or shared. Serialize all executions against it.
Each run creates a unique bounded non-secret marker and fresh UUIDs so an
interrupted run can be identified and cleaned without scanning unrelated graph
content.

### Cold-bootstrap and synchronize a sender

Start a sender worker process with an empty temporary application-support
directory. Restore and reconcile the configured identity, answer token
challenges, select only the configured graph, and submit the graph password if
requested. Require public state to progress through catalog discovery, encrypted
graph bootstrap, graph attachment, opening pull, and `Current`.

The sender begins without a mirror, catalog cache, checkpoint, outbox, or secret
state. The runner supplies one isolated temporary Keychain shared only by the
sequential sender and receiver in the supervised child. The test must not read or
delete ambient developer Keychain entries.

Obtain a mutation basis and one active journal-page parent from public
`Graph_request` read responses. Insert one block with the run marker and a fresh
block UUID under that parent through another `Graph_request`. Require
`Mutation_result Applied`, then wait through public state until synchronization
returns to `Current`. After stopping the sender, require its durable cursor and
checksum to advance and its outbox to be empty.

An empty outbox alone is not sufficient evidence of remote persistence.

### Recover and clean up through an independent worker

Wait for the sender process and `Worker_runtime` to stop completely. Start a
receiver with a second empty support directory and no access to sender files.
Authenticate the same account, select the same graph, complete bootstrap and
opening pull, and reach `Current`.

Read the inserted block by UUID through `Graph_request`. Require its exact marker
title and journal parent. This independent clean recovery proves that
the mutation traversed `https://api.logseq.io`; reopening the sender mirror would
prove only local durability.

Delete the marker subtree through a receiver `Graph_request`, wait for
authoritative completion and `Current`, then stop the receiver and require an
empty durable outbox.

A later run may remove orphaned markers from interrupted runs, but cleanup must
be bounded to this test's UUID/title namespace and use public worker reads and
mutations. It must never delete unrelated graph data.

### Make the online lane explicit

Do not attach this test to the default `runtest` alias. Provide one explicit
automated online alias or tool command. The command accepts only
`LOGSEQ_DB_WORKER_E2E_USERNAME`, `LOGSEQ_DB_WORKER_E2E_PASSWORD`,
`LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD`, and `LOGSEQ_DB_WORKER_E2E_GRAPH_NAME`; it
performs login, token acquisition, named graph discovery, both worker runs,
verification, and cleanup without interactive steps. Once selected,
authentication failure, network outage, deployed-service failure, or timeout is
a test failure rather than a silent skip.

All waits must be bounded and phase-specific. Diagnostics may contain client
label, redacted worker phase, graph phase, sync phase, cursor, outbox state, and
last public event kind. They must not contain the token, authenticated user ID,
graph password, E2EE material, transaction body, page title, or an unbounded raw
exception.

## Decision

Accept the replacement proposal with these resolved choices:

- automate deployed authentication from `LOGSEQ_DB_WORKER_E2E_USERNAME` and
  `LOGSEQ_DB_WORKER_E2E_PASSWORD`; do not require an operator to copy an ID token
  or graph ID;
- select the exact `LOGSEQ_DB_WORKER_E2E_GRAPH_NAME` match from the account
  catalog, require that match to be unique and encrypted, and fail safely before
  mutation if that invariant is not true;
- run sender and clean receiver sequentially;
- submit `LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD` automatically when E2EE recovery
  is requested, but do not require recovery to occur when an existing correctly
  scoped Keychain entry is usable; and
- ship the scenario first as an explicit macOS online command outside default
  `runtest`. A CI schedule can call the same non-interactive command later without
  changing the test design.

## Alternatives considered

### Keep both the loopback and deployed E2E scenarios

Keeping both gives stronger coverage: the loopback lane owns exact ordering and
wire assertions, while the deployed lane owns service compatibility. It is not
selected because the requested direction is to remove the existing worker E2E,
and the repository should not retain parallel test paths. Focused component
tests must carry deterministic invariant coverage after removal.

### Extend only the loopback E2E

A controlled server cannot prove compatibility with deployed authentication,
catalog, snapshot, and WebSocket behavior. More simulated assertions do not
close the production-service gap.

### Test `Application.app` or Flutter

Application and UI coverage would add unrelated host, rendering, and interaction
failure modes. The requested boundary is only `logseq_db_worker.bonsai`, so the
test directly drives its public worker service.

### Use one worker and trust an empty outbox

An empty sender outbox and `Current` show that the sender accepted an
authoritative result, but not that a clean client can reconstruct the mutation
from remote state. The second empty support directory provides that evidence.

### Keep two clients concurrently live

The existing loopback scenario uses concurrent clients to validate change
notification. Sequential deployed clients reduce remote timing and account
contention while still proving upload and remote recovery. Concurrent execution
should be selected only if deployed `changed` delivery is itself required.

### Use a personal account or graph

This avoids provisioning but risks user data, prevents reliable cleanup, and
makes repeated execution unsafe. A dedicated destructive graph is required.

### Run the online scenario by default

That would make normal development depend on secrets, network availability,
mutable remote state, and macOS Keychain behavior. The test remains opt-in.

## Acceptance criteria

- Exactly one worker sync E2E remains. It uses `https://api.logseq.io`; the
  controlled loopback worker E2E, its exclusive server code, exclusive child
  protocol, exclusive certificates, and exclusive dependencies are removed.
- The replacement drives only the public
  `Logseq_db_worker_bonsai_service` request/response/push interface through
  `Worker_runtime`. It neither mounts nor imports `Application.app` and tests no
  UI.
- Both clients use production system TLS verification, `Managed_coordinator`,
  `Logseq_sync.Core`, `Logseq_sync.Effect_runner`, Engine, SQLite checkpoint, and
  durable outbox paths.
- The command receives the dedicated test account only through
  `LOGSEQ_DB_WORKER_E2E_USERNAME` and `LOGSEQ_DB_WORKER_E2E_PASSWORD`, signs in
  automatically, obtains a fresh ID token, and selects the exact
  `LOGSEQ_DB_WORKER_E2E_GRAPH_NAME` match from the returned catalog. Other graph
  entries are allowed, while the named match must be unique and encrypted. E2EE
  recovery uses only `LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD`.
- The sender starts with an empty support directory, discovers and selects the
  configured encrypted graph, completes any required E2EE bootstrap,
  opens the graph, and reaches `Current`.
- The sender inserts one uniquely marked block under an existing journal page only
  through `Graph_request`; after authoritative completion its durable cursor and
  checksum have advanced and its outbox is empty.
- After complete sender shutdown, a receiver with a distinct empty support
  directory bootstraps the graph and reads the exact block and parent by UUID
  without reading sender files.
- The receiver deletes the marker subtree through a public mutation, reaches
  `Current`, and finishes with an empty outbox.
- Account identifier, account password, E2EE password, token, user ID, private
  key, wrapped graph key, plaintext graph key, and transaction payload do not
  appear in source, process arguments, logs, diagnostics, fixtures, support data
  where not production-required, or retained artifacts.
- Both processes close their worker sessions, engines, sockets, graph-key
  buffers, and temporary directories. `Worker_runtime` is `Idle` between clients
  and at completion.
- Execution is serialized per dedicated graph, every wait is bounded, and a
  bounded public-interface cleanup policy handles interrupted markers.
- The test has a non-interactive explicit opt-in command and is absent from
  default `runtest`. Missing or invalid username, account-password,
  E2EE-password, or graph-name ENV values fail before authentication, worker
  startup, or remote mutation.
- Focused Core, runner, protocol, E2EE, Engine, storage, source-boundary, and
  application tests remain and pass after removal of the hermetic E2E.
- The online command, `dune runtest`, `git diff --check`, and
  `spec-dev-tool check --all` pass in their appropriate environments.

## Risks

- Removing the loopback E2E loses deterministic proof of exact HTTP/WSS message
  counts, cross-client token isolation, ciphertext capture,
  outbox-before-first-byte ordering, acknowledgement-versus-echo behavior,
  server cursor allocation, live change broadcast, and socket shutdown. Focused
  tests cover components, but no single hermetic scenario will cover their full
  composition.
- `https://api.logseq.io` is mutable external state. Deployment changes,
  throttling, snapshot lag, account policy, or outage can fail the lane without a
  repository regression.
- Deployed sign-in can be throttled or changed independently of sync. The helper
  must obtain a fresh token for each run without logging authentication responses.
- The standalone test host uses a DEBUG-only disposable file-based Keychain, so
  the lane does not validate the production app's Data Protection Keychain
  entitlement. Signed Runner tests remain responsible for that host boundary.
- A crash between creation and deletion leaves remote data. Orphan cleanup must
  be strictly bounded to the test namespace.
- Two cold bootstraps may be slow or rate-limited. The test graph should stay
  small and waits must be finite but tolerant of deployed latency.
- Sequential clients do not prove live `changed` delivery to a second connected
  client.

## Consequences

- `test_managed_sync_e2e.ml` is now the only worker sync E2E and drives
  `Logseq_db_worker_bonsai_service.service` against `https://api.logseq.io` with
  sequential cold sender and receiver support directories.
- The deployed lane is available only through
  `dune build @logseq_db_worker/test/managed-sync-online-e2e`; default
  `dune runtest` builds and runs only the deterministic support checks.
- Cognito authentication consumes the username and password environment
  variables, sends credentials to the bounded helper over stdin, and keeps
  credentials, the E2EE password, tokens, user IDs, graph IDs, graph names, block
  titles, and transaction bodies out of arguments and diagnostics. Catalog
  selection uses `LOGSEQ_DB_WORKER_E2E_GRAPH_NAME` only for an exact name match,
  and E2EE recovery uses `LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD`.
- The online executable compiles and injects the production Swift platform
  crypto provider from `flutter/JournalE2EECrypto.swift` through a temporary
  dynamic library, scopes its DEBUG-only storage mode to a temporary file-based
  Keychain, then removes every owned provider artifact after the child exits.
- The loopback server, child protocol, test TLS certificates, fake crypto and
  token paths, and their direct worker test dependencies have been removed.
- A deployed run requires the dedicated account credentials and the configured
  encrypted graph name and E2EE password. Repository verification can validate
  fail-fast behavior without those values, but only the configured online alias
  can validate the mutable deployed service contract.

## Questions

None.
