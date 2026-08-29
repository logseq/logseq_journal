# Encrypted Read Path Contract Tests

## Problem

The pure sync-core contract does not currently preserve a decryption capability
when an encrypted graph advances from a downloaded snapshot to worker-owned mirror
activation. The worker therefore imports protected `block/title` and `block/name`
values as ciphertext and the Timeline renders their Transit AES-GCM envelopes.

The public Core contract tests also leave three adjacent encrypted read boundaries
under-specified: an existing encrypted mirror must not attach before a correctly
scoped graph key is available, an authoritative encrypted pull must not reach the
worker before decryption, and any authoritative decryption failure must stop the
batch without advancing its checkpoint. These gaps allow ownership refactors to
drop crypto wiring while the public API test suite remains green.

## Proposal

Add four scenarios to `logseq_sync/test/core_contract.ml`, using only values and
types exposed by the virtual `Logseq_sync.Core` interface:

1. An encrypted cold bootstrap carries the current graph-key handle into snapshot
   activation and refuses activation when that capability is unavailable.
2. An encrypted warm mirror waits for a graph key before attachment and rejects a
   key handle belonging to another graph scope.
3. An authoritative pull containing protected values issues a typed decryption
   request and does not delegate worker application until decryption completes.
4. A failed authoritative decryption is fail-closed: it delegates no application,
   advances no checkpoint, and reports an E2EE-stage failure.

Extend `logseq_sync/spec/core.mli` only where the public contract cannot currently
express these invariants. Keep graph keys runner-owned: snapshot activation may
carry only an opaque scoped handle. Add the minimal effect-runner operation needed
by the worker to resolve that handle while materializing a plaintext snapshot; do
not expose raw key bytes.

## Decision

Adopt the four public Core contract scenarios and make encrypted snapshot
activation carry `graph_key_handle option`. Core supplies `Some handle` only for an
encrypted selected graph after validating that the handle belongs to the current
graph scope; unencrypted activation supplies `None`.

Keep the raw graph key inside `Effect_runner`. Expose a narrow
`decrypt_protected_value` operation that resolves the opaque handle internally,
uses the existing tolerant E2EE decoder, and returns only a protected plaintext
string. The worker turns that operation into the callback already accepted by
`Synced_mirror.bootstrap`. Classify a wrong-scope graph key and an authoritative
decryption failure as `During_e2ee` and never delegate the affected worker apply.

## Alternatives considered

### Test only the worker snapshot importer

Rejected because it would prove the importer can decrypt when given a callback but
would not catch the actual regression, which is the loss of that capability at the
Core-to-worker activation boundary.

### Put raw graph-key bytes in the activation request

Rejected because Core is pure policy, graph-key material belongs to the effect
runner, and raw secrets must not cross the public state or worker-effect contract.

### Leave the new regression test failing

Rejected because a permanently red suite does not protect subsequent work. Follow
red-green-refactor: demonstrate each missing behavior, then add the smallest
contract and implementation changes that make the scenarios pass.

## Acceptance criteria

- All four scenarios exercise `Logseq_sync.Core` only through `spec/core.mli`.
- Encrypted snapshot activation carries an opaque handle scoped to the selected
  graph, and the worker uses it to materialize protected snapshot strings as
  plaintext.
- An encrypted existing mirror cannot attach with no key or a key from another
  graph scope.
- Encrypted authoritative transactions are delegated only after successful
  decryption.
- Decryption failure emits no authoritative apply instruction, advances no public
  cursor, and is classified as `During_e2ee`.
- The targeted sync tests and the repository's relevant worker tests pass.

## Risks

- Adding an opaque handle to a worker effect creates another cross-owner protocol
  value; scope validation must remain fail-closed at both Core and effect-runner
  boundaries.
- Snapshot materialization is synchronous in the worker today. The minimal runner
  API must not expose raw keys or accidentally make runner-owned asynchronous state
  available after cancellation.
- Mixed deployed snapshots contain both plaintext and encrypted protected strings;
  the existing tolerant protected-value decoder must remain unchanged.

## Consequences

The Core-to-worker contract now makes snapshot decryption capability explicit and
scope-checkable without exposing key bytes. Fresh encrypted snapshot bootstrap
materializes the same plaintext mirror representation used by authoritative pull
and local projection. The four public-contract tests protect cold bootstrap, warm
mirror attachment, authoritative decrypt-before-apply ordering, and fail-closed
decryption behavior.

`Effect_runner` gains one synchronous, handle-based protected-value operation for
worker-owned snapshot materialization. This is intentionally narrower than making
crypto dependencies or graph-key bytes available to the worker.

## Questions

- None. The reported ciphertext rendering, the previous activation implementation,
  and the existing E2EE decision documents establish the required behavior.
