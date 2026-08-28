# Logseq Sync E2ee Roundtrip

## Problem

`logseq_sync/test` verifies the individual E2EE, transaction, protocol, pending,
and replay boundaries, but no test carries one protected mutation through the
complete package-owned sync path. The strongest existing transaction test stops
after encoding and decoding against one in-memory database. The E2EE scenario
separately verifies the upstream key envelope and graph-key lifecycle, while the
replay scenario separately verifies durable SQLite commit. These isolated tests
can all pass when the components disagree about the value shape crossing a seam.

The missing behavior is an observable roundtrip from a plaintext mutation on one
client to durable plaintext state on an independent receiving client, with only
ciphertext crossing the simulated remote boundary. The path must cover:

1. ownership of a 32-byte plaintext graph key;
2. encryption of a protected transaction value;
3. normalized Transit transaction encoding;
4. durable pending-intent storage before submission;
5. `tx/batch` wire encoding;
6. a server-shaped `pull/ok` response decoded through the public protocol;
7. continuity and E2EE checksum validation;
8. protected-value decryption during replay; and
9. atomic persistence to an independent SQLite-backed DataScript database.

The existing decision in
`docs/agent-guide/implemented/testing/2026-08-27-reduce-logseq-sync-tests-to-ten.md`
historically reduced the package to ten registered Alcotest scenarios. Scenario
count is no longer a package-boundary invariant: this roundtrip is independently
registered because the cross-component behavior deserves its own selectable name
and failure report, while future additions or removals do not require updating a
source-boundary count assertion.

Cryptographic primitive ownership is another boundary. `logseq_sync` owns the
E2EE protocol and passes cryptographic operations through a capability, while the
production RSA-4096 OAEP, PBKDF2-HMAC-SHA256, AES-GCM, and Keychain implementation
lives in the Apple host. A package-level Dune test can prove capability wiring,
key non-disclosure, wire formats, and persistence with a deterministic crypto
implementation, but it cannot by itself prove the Apple `CryptoKit` and
`Security` implementation without crossing into the native test harness.

## Proposal

Add one independently registered package-level scenario named `protected
transactions complete a durable two-client roundtrip`.

The sender and receiver start from separate SQLite databases containing the same
baseline graph and active sync checkpoint. The sender owns a 32-byte
`Graph_key.t`, encodes a mutation that changes both a protected `block/title` and
an unprotected structural attribute, and encrypts the title through
`Graph_key.encrypt_value`. The test persists the resulting normalized Transit in
`Pending`, closes and reopens the pending store, and uses the restored bytes to
create a `Protocol.outgoing_tx` and encode a `tx/batch` message.

A deliberately small in-process server boundary parses only enough of the
client-produced batch to copy its transaction into a JSON `pull/ok` response. It
must not decode, inspect, or reconstruct the embedded Transit. The test asserts
that the pending entry's `encodedTx` and the batch/pull wire do not contain the
plaintext title. The pending envelope also retains the local structured mutation,
whose plaintext is local durable command state rather than remote wire data. The
test then decodes the response with
`Protocol.decode_server_message` and applies it to the receiver with
`Replay.apply_pull`, using `Graph_key.decrypt_value` for protected attributes.

The receiver must commit the expected plaintext title and structural value,
advance its server cursor, persist the E2EE checksum, and restore the same state
after closing and reopening SQLite. The sender's and receiver's key values are
separate `Graph_key.t` instances created from equal bytes so the test cannot pass
by sharing mutable database or key objects. Both graph keys are cleared during
teardown, and an assertion after clear proves that the key can no longer encrypt
or decrypt.

The crypto capability should be deterministic and authenticated enough for the
package test to detect the wrong key, IV, ciphertext, or altered payload. It must
not be a plaintext identity transform. This capability tests package composition,
not the security of a hand-written cipher, so it should stay local to the test and
use an explicit test envelope rather than imitate production cryptography.

No production interface, package dependency, `spec/` OCaml file, or Dune stanza
is expected to change. Existing native Swift contract tests remain responsible
for the actual RSA, PBKDF2, AES-GCM, and Keychain primitives unless the requested
scope explicitly includes a cross-language Apple integration lane.

## Decision

Implement the proposed portable two-client roundtrip as an independently
registered Alcotest scenario. Do not enforce the total number of package tests in
`source_boundary_test`; test inventory is not a package dependency or ownership
boundary. Use the deterministic authenticated crypto capability at the
`logseq_sync` boundary and leave Apple native cryptographic execution in the
existing Swift contract suites.

## Alternatives considered

### Fold the roundtrip into the existing E2EE scenario

This would combine key contract checks and a multi-component durable integration
lifecycle under one selection and failure report. The roundtrip remains
independently registered so it can be selected and diagnosed on its own; no
scenario-count budget is involved.

### Extend the transaction-only roundtrip

`scenario_transactions` already encrypts, encodes, decodes, and compares two
in-memory databases. Extending only that helper would remain fast, but would still
omit pending durability, public protocol decoding, cursor/checksum validation,
atomic replay, and SQLite reopen. It would not close the identified seam.

### Drive the full Manager and real WebSocket transport

A local HTTP/WebSocket server could exercise Manager actions and Eio transport in
addition to transaction and replay behavior. This would introduce scheduling,
socket, TLS, and authentication setup unrelated to the core data roundtrip, while
the current Manager and transport scenarios already cover their ordering and
generation fences. It would also make it difficult to attribute a failure to the
E2EE data path.

### Invoke the Apple native crypto implementation from the package test

This would prove the concrete RSA-4096 OAEP, PBKDF2, AES-GCM, and Keychain path,
not just the package capability boundary. It is platform-specific, requires the
Swift build/test harness and signed Keychain considerations, and cannot remain a
portable `dune runtest logseq_sync/test` scenario. It is a valid additional lane
if native cryptographic execution is part of the requested meaning of “complete.”

### Use one database as both sender and receiver

Echoing the encoded transaction into the same database is simpler but can hide
state sharing and accidental reliance on the sender's already-applied mutation.
Independent sender and receiver databases provide a stronger final-state oracle.

## Acceptance criteria

- One new `logseq_sync` Alcotest scenario carries a protected mutation from a
  sender database through graph-key encryption, pending persistence, `tx/batch`,
  decoded `pull/ok`, E2EE replay, and receiver SQLite reopen.
- Sender and receiver use independent database sessions and independent
  `Graph_key.t` values created from the same 32-byte key material.
- The pending entry's `encodedTx`, the encoded transaction, `tx/batch`, and
  `pull/ok` bytes do not contain the protected plaintext. The local structured
  mutation remains explicit and is not treated as remote ciphertext.
- The simulated server treats the encoded transaction as opaque and does not call
  package transaction or E2EE decoders.
- The receiver restores the exact protected plaintext and unprotected structural
  value, advances the expected server cursor, and durably stores the expected
  E2EE checksum.
- A mutated ciphertext, wrong graph key, or invalid authentication data is
  rejected without advancing the receiver database or sync checkpoint.
- Both graph keys are cleared in teardown, and use after clear fails.
- `logseq_sync/test` registers the roundtrip scenario and retains no dependency on
  `logseq_db_worker`; source-boundary tests do not assert the suite's scenario
  count.
- `dune runtest logseq_sync/test`, package source-boundary checks, and the relevant
  downstream worker sync integration tests pass.
- `spec-dev-tool check --all` passes.

## Risks

- The additional scenario increases suite runtime; its setup must remain bounded
  and its assertions precise.
- A deterministic crypto capability can prove composition and fail-closed wiring,
  but it cannot establish production cryptographic correctness.
- Reusing storage-fixture helpers from `scenario_replay` could create cross-scenario
  coupling. Common database setup should move only to the sync-owned test-support
  library when it is genuinely shared.
- A server-shaped in-process echo is not a live service compatibility test. It
  proves that the client can consume its own emitted transaction through the
  deployed protocol shapes, not that a remote Logseq deployment accepts it.
- E2EE checksums intentionally exclude protected title/name plaintext. The final
  plaintext value therefore needs its own database assertion; checksum equality
  alone is insufficient.
- The pending envelope persists the structured local mutation as well as its
  encrypted wire transaction. This scenario verifies confidentiality at the
  remote boundary; encryption of local command state is a separate storage-policy
  decision.
- Cleanup must close both storage sessions before deleting temporary directories
  and clear both graph keys even when an intermediate assertion fails.

## Consequences

`logseq_sync/test` now includes the new roundtrip scenario without treating the
suite's current scenario count as a source boundary. The scenario uses two
independent SQLite-backed clients and separate graph-key owners, persists and
reopens the sender's pending transaction, crosses only public transaction and
protocol encoders at the simulated remote boundary, rejects tampered ciphertext
and a wrong graph key without receiver advancement, and reopens the receiver to
prove that plaintext state and the E2EE checkpoint are durable.

The test remains portable because its deterministic authenticated crypto
capability implements the `logseq_sync` boundary without invoking Apple native
frameworks. Existing Swift contract suites continue to own RSA-4096 OAEP,
PBKDF2-HMAC-SHA256, AES-GCM, and Keychain verification. No production interface,
package dependency, Dune stanza, or OCaml file under `spec/` changed.

## Questions

- Resolved: the scenario stops at the portable `logseq_sync` package boundary and
  uses a tamper-detecting deterministic crypto capability. Apple native
  cryptographic primitives remain covered by their native contract tests.
- Resolved: the scenario models two independent clients and verifies receiver
  state after closing and reopening SQLite.
- Resolved: scenario count is not enforced. The roundtrip remains independently
  registered, and source-boundary validation checks ownership and dependency
  rules rather than the number of tests.
