# Shared Mutation Fingerprint

## Problem

Mutation identity currently has two independent fingerprint implementations.
`logseq_db_worker/lib/engine.ml` serializes `Mutation.t` with OCaml `Marshal`
and hashes the bytes with SHA-256 for the in-memory mutation cache. In contrast,
`logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml` serializes the
mutation with `Mutation.to_yojson` and stores the complete JSON string as the
durable outbox fingerprint.

The two values do not agree for the same mutation and do not share one owner.
The managed coordinator therefore cannot reuse the Engine computation when it
checks a durable outbox record before preparing a mutation. Future mutation
shape or encoding changes can also update one implementation without updating
the other.

The durable implementation is already causing an application failure. The
outbox codec accepts fingerprints only when their encoded length is between 1
and 256 bytes, but a minimal Capture `Insert_blocks` mutation produces roughly
269 bytes of compact JSON before any captured source is included. New-record
validation checks only aggregate outbox count and bytes, so the oversized raw
JSON fingerprint can be committed. The next outbox decode then rejects the
record with `invalid outbox record`. The durable record remains unreadable and
subsequent managed mutations cannot pass the coordinator's deduplication gate.

The fingerprint has one semantic purpose: combine with `mutation_id` to
distinguish an idempotent retry of the same mutation from reuse of that ID for a
different mutation. It is local deduplication metadata and is not part of the
remote transaction submission payload. That domain meaning belongs with the
mutation type, not independently with Engine and the managed coordinator.

## Proposal

Make `Logseq_db_types.Mutation` the sole owner of mutation payload encoding and
fingerprinting. Add an opaque derived value with the following conceptual
surface:

```ocaml
type identity

val identify : t -> identity
val identity_payload : identity -> string
val identity_fingerprint : identity -> string
```

`identify` should serialize the mutation once through the existing explicit
`Mutation.to_yojson` representation, encode that value as compact JSON, retain
that exact string as the payload, hash the same string bytes with SHA-256, and
retain the lowercase hexadecimal digest as the fingerprint. The fingerprint is
therefore fixed at 64 ASCII characters, independent of mutation payload size
and safely inside the durable outbox's 256-byte bound. The opaque value prevents
callers from pairing a payload with a digest derived from different bytes.

Use the explicit mutation JSON rather than `Marshal` because the fingerprint is
persisted across process restarts and application upgrades. `Marshal` describes
the current OCaml runtime representation and is appropriate neither as a
durable format nor as a package-boundary contract. `Mutation.to_yojson` is
already the mutation's explicit request representation and gives the digest a
single reviewable input.

Remove both caller-owned calculations and pass the derived identity through the
mutation path instead of recomputing it:

- direct Engine mutation execution derives one identity and uses its fingerprint
  for cache lookup and insertion;
- the managed coordinator derives one identity before durable outbox lookup,
  uses its fingerprint for the retry comparison, and passes the same opaque
  identity into managed mutation preparation;
- managed preparation uses the identity payload for `mutation_payload` and its
  fingerprint for both Engine cache insertion and sync-core outbox construction;
  and
- no worker, sync, or application module hashes or stores a substitute raw
  serialization under the fingerprint name.

Keep `mutation_payload` separate. It remains the complete mutation JSON needed
as durable mutation data, but it is taken from the shared identity rather than
encoded again; `mutation_fingerprint` becomes only that payload's compact
identity digest. Do not send the fingerprint in `tx/batch`, change remote
`tx-id` semantics, or move outbox codec ownership into `logseq_db_types`.

This encode-once shape is preferable to a standalone `fingerprint : t ->
string` helper. The current managed path serializes the mutation to JSON in the
coordinator, serializes it to JSON again for `mutation_payload`, and separately
serializes it with `Marshal` before hashing. The proposed path performs one JSON
serialization and one linear SHA-256 pass over the resulting string. It removes
work and allocation from the failing managed Capture path while making the
payload and fingerprint agree by construction.

Add focused `logseq_db_types` contract tests with stable fingerprint vectors
covering at least Capture `Insert_blocks`, page creation, property mutation,
and a content change under a reused mutation ID. Worker tests should prove that
the Engine cache and managed durable-outbox path produce the same value, accept
same-ID/same-content retries, and reject same-ID/different-content reuse. A
Capture integration test should prove that a newly committed record round-trips
through the outbox codec and no longer produces `invalid outbox record`.

Capture before-and-after benchmark results for identity derivation and managed
mutation admission using representative Capture payloads and a mutation near
`maximum_request_bytes`. Verification should show one payload serialization per
accepted mutation, linear time and space in payload bytes, bounded 64-byte
fingerprint output, and no material end-to-end mutation-throughput regression.
The benchmark belongs in the implementation evidence; wall-clock thresholds
should not become flaky unit-test assertions.

This is a breaking cutover. Remove the obsolete `Marshal` and raw-JSON
fingerprint paths; do not retain aliases, fallback comparisons, dual writes, or
format migrations.

## Decision

Adopt the proposal as a breaking cutover. `Logseq_db_types.Mutation.identity`
is the sole production representation of a mutation payload paired with its
SHA-256 fingerprint. Direct Engine execution and the managed coordinator derive
that identity once per admission, and managed Engine preparation consumes the
already-derived value. The Engine `Marshal` digest and coordinator raw-JSON
fingerprint are removed without compatibility comparisons or migration.

## Alternatives considered

### Keep fingerprinting in Engine and expose it to the coordinator

This would make the immediate callers agree, but it leaves mutation identity
owned by an execution component rather than the package that defines and
encodes mutations. It also makes lower-level or future consumers depend on the
worker merely to derive mutation metadata.

### Put a fingerprint helper in `logseq_sync`

The durable outbox is sync-owned, but direct Engine mutations require the same
deduplication semantics without depending on `logseq_sync`. Placing the helper
there would invert the existing package boundary and keep mutation identity
separate from `Mutation.t`.

### Continue storing complete mutation JSON as the fingerprint

Exact JSON equality can distinguish retries from ID reuse, but the outbox
already stores the complete JSON as `mutation_payload`. Duplicating it as the
fingerprint wastes durable space, grows with user content, violates the codec's
fixed bound, and does not provide a compact identity value.

### Standardize on the existing `Marshal` SHA-256

This produces the required bounded digest and is already used by Engine, but
`Marshal` is tied to OCaml representation details. Persisting its digest makes
runtime representation an undocumented durable compatibility contract. The
explicit mutation JSON is the appropriate stable digest input.

### Introduce a new fingerprint package or module

The operation is small and its input is exactly `Mutation.t`. A separate package
would add a dependency and naming boundary without owning any independent
domain concept. `Logseq_db_types.Mutation` is the narrowest shared owner.

## Acceptance criteria

- `Logseq_db_types.Mutation` exposes the only production mutation identity
  derivation, containing the exact compact payload and a 64-character lowercase
  SHA-256 hexadecimal fingerprint of those same bytes.
- The digest input is the compact explicit `Mutation.to_yojson` representation;
  no production mutation fingerprint uses `Marshal` or stores unhashed mutation
  JSON.
- Each direct or managed mutation admission derives at most one identity; the
  managed path does not independently re-encode its payload in the coordinator,
  Engine, or sync core.
- Engine direct-mutation deduplication, managed mutation preparation, and the
  managed coordinator's durable outbox deduplication all consume the shared
  identity.
- `mutation_payload` remains complete mutation JSON while
  `mutation_fingerprint` contains only the shared digest.
- Same-ID/same-content retries are reported as already applied without executing
  the mutation again; same-ID/different-content requests are rejected.
- A Capture `Insert_blocks` mutation creates a durable outbox record that
  encodes and decodes successfully, and subsequent managed mutations do not fail
  with `invalid outbox record`.
- Stable vectors cover representative mutation families and prove that Engine
  and coordinator callers cannot drift to separate algorithms.
- Before-and-after benchmark evidence covers representative and maximum-sized
  mutations, confirms linear behavior and one JSON serialization per mutation,
  and shows no material end-to-end mutation-throughput regression.
- The obsolete Engine-local and coordinator-local implementations are removed;
  no compatibility calculation, fallback comparison, or migration remains.
- Focused type, sync-core, worker, and application integration tests pass, along
  with `dune build @all`, `dune runtest`, and `git diff --check`.

## Implementation evidence

`logseq_db_types/lib/mutation.ml` now owns the opaque identity, compact payload,
and SHA-256 digest. Direct Engine execution derives one identity. The managed
coordinator derives one identity before durable lookup and passes it to Engine
preparation; Engine reads both the payload and fingerprint from that value.
Source-boundary tests reject the removed Engine `Marshal` calculation and the
removed coordinator `Mutation.to_yojson` calculation.

Stable type-level vectors cover Capture `Insert_blocks`, journal page creation,
status property mutation, and changed content under one mutation ID. The Engine
suite covers same-ID/same-content retry, same-ID/different-content rejection,
and a Capture mutation that is prepared, encrypted, committed to the durable
outbox, loaded, and decoded with the shared 64-byte fingerprint.

The reproducible benchmark command is:

```sh
dune exec logseq_db_worker/tool/mutation_identity_benchmark.exe
```

Results below were captured on an Apple M4 Max running macOS 26.6.2. The
before-managed-identity operation reproduces the removed coordinator JSON,
Engine payload JSON, and Engine `Marshal` digest work. The before full-admission
value is modeled as the measured common Engine planning cost plus that measured
legacy identity work; the after full-admission value invokes the implemented
`Mutation.identify` plus `Engine.prepare_managed_mutation` directly.

| Capture sample | Payload | Measurement | Before | After | Change |
| --- | ---: | --- | ---: | ---: | ---: |
| Representative | 1,301 B | Direct identity time | 2.796 us | 4.531 us | +62.1% |
| Representative | 1,301 B | Managed identity time | 6.235 us | 4.531 us | -27.3% |
| Representative | 1,301 B | Managed identity allocation | 11,487 B | 5,392 B | -53.1% |
| Representative | 1,301 B | Full managed admission time | 741.283 us | 739.579 us | -0.2% |
| Near maximum request | 976,299 B | Direct identity time | 2.268 ms | 3.200 ms | +41.1% |
| Near maximum request | 976,299 B | Managed identity time | 4.372 ms | 3.200 ms | -26.8% |
| Near maximum request | 976,299 B | Managed identity allocation | 7,006,593 B | 3,015,656 B | -57.0% |
| Near maximum request | 976,299 B | Full managed admission time | 85.204 ms | 84.031 ms | -1.4% |

The durable JSON-based direct identity is intentionally more expensive than the
removed runtime-representation `Marshal` digest in isolation. Managed admission,
which was the failing application path, removes two redundant serializations
and has no end-to-end throughput regression in these samples. Increasing the
payload by 750 times increased shared identity time by 706 times and retained a
64-byte fingerprint in both cases, consistent with linear payload work and
bounded output. No benchmark wall-clock value is a unit-test assertion.

Final verification passed `dune build @all`, `dune runtest`, `dune build @fmt`,
`git diff --check`, and `spec-dev-tool check --all`. The bonsai_flutter macOS
toolchain doctor passed, the Flutter host suite passed 21 tests with 5 intentional
skips, `flutter analyze` reported no issues, and the debug macOS application
built and launched through `bonsai-flutter`. In the running app, the
`ocaml-sync-test` managed graph opened and accepted two consecutive Capture
submissions. Both inputs cleared after commit and the second submission produced
no `invalid outbox record`, exercising the durable-decode failure boundary that
the old raw-JSON fingerprint broke.

## Consequences

- `logseq_db_types` now depends on `digestif` and owns the durable identity
  encoding contract in addition to the mutation JSON contract.
- A persisted mutation fingerprint is always 64 lowercase hexadecimal bytes,
  while `mutation_payload` remains the complete compact mutation JSON.
- Direct and managed deduplication compare the same digest input and cannot
  drift through caller-local algorithms.
- Changing mutation JSON field order or encoding changes stable fingerprint
  vectors and requires an explicit contract review.
- Existing outbox records written by the broken raw-JSON implementation receive
  no decoder, fallback, dual-read, migration, or automatic repair path.

## Risks

- `logseq_db_types` currently depends only on `yojson`. Owning SHA-256 there
  requires adding the repository's existing `digestif` dependency to that
  package and its build metadata.
- SHA-256 requires one additional linear read over the retained payload string.
  The current paths already hash a separate serialization, and the encode-once
  design removes larger duplicate serialization work, but benchmark evidence is
  still required rather than assuming the end-to-end cost is negligible.
- JSON object field order is currently deterministic because `Mutation.to_yojson`
  constructs ordered association lists. A future JSON encoder refactor can
  change fingerprints even when decoded mutation meaning stays equivalent;
  stable vectors must make that an explicit reviewed change.
- Fingerprints persisted by the broken implementation will not match the new
  digest and may already be undecodable because they exceed 256 bytes. They are
  outside code recovery scope: no compatibility decoder, fallback comparison,
  migration, or automatic cache repair will be added. Existing test graphs will
  be deleted manually before validation.
- SHA-256 makes accidental mutation-ID reuse detectable with negligible
  collision risk, but it is not an authentication mechanism and must not be
  treated as proof against a malicious party.

## Questions

None. The user confirmed that existing broken test graphs will be deleted
manually and require no code-owned recovery. To avoid duplicate encoding and
protect performance, the shared operation will derive the retained compact JSON
payload and its SHA-256 fingerprint together in `logseq_db_types` and pass that
opaque identity through both mutation paths.
