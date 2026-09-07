# SQUUID Block Identities

## Problem

New block identities currently come from `fresh_identity` in
`app/application.ml`. It hashes wall-clock time, a process-local counter, and the
PID with `Digest.string`, then formats the digest with version 4 and variant
markers. Mutation IDs use the same helper. This is a custom MD5-based identity
scheme without a dedicated block identity contract or time-ordered output.

The user requested a SQUUID generator based on
[yetanalytics/colossal-squuid](https://github.com/yetanalytics/colossal-squuid)
for new block UUIDs. The user confirmed the monotonicity scope and ownership
design on 2026-09-07 and requested transition to proposed after answering all
exploration questions. This proposal records the agreed design for implementation.

The two current allocation sites are the direct capture path calling
`Journal_capture.admit_save` and the child creation path calling
`Journal_detail.admit_child`. Both already pass `block_id` and `creation_time`
explicitly. `Graph_types.Uuid` provides parsing, normalization, and comparison,
but does not generate identities.

## Proposal

Introduce one OCaml SQUUID implementation and route both new-block allocation
sites through a single application-owned generator instance.

Guarantee strict monotonicity within one serialized process-lifetime generator,
including during clock rollback. Do not persist generator state or guarantee
ordering across process restarts or devices. The user accepted this scope.

### Reference algorithm

Reference revision: `6b7a7eb3235d61c5a0e8f62123985607c7d40de5`, inspected on
2026-09-07. Relevant upstream sources are
[the generator](https://github.com/yetanalytics/colossal-squuid/blob/6b7a7eb3235d61c5a0e8f62123985607c7d40de5/src/main/com/yetanalytics/squuid.cljc)
and [UUID operations](https://github.com/yetanalytics/colossal-squuid/blob/6b7a7eb3235d61c5a0e8f62123985607c7d40de5/src/main/com/yetanalytics/squuid/uuid.cljc).

Use the upstream bit layout:

```text
tttttttt-tttt-8rrr-vrrr-rrrrrrrrrrrr
t: 48-bit Unix timestamp in milliseconds
r: random payload
v: variant nibble in 8, 9, a, b (high bits 10)
```

The version and variant reserve six bits, leaving 74 payload bits. This is the
reference library's v8 format; it is not the seconds-based Datomic SQUUID format.
Use lowercase canonical UUID text and return `Graph_types.Uuid.t`.

For a later timestamp, combine that timestamp with fresh random payload. For an
equal or earlier timestamp, retain the last timestamp and increment the prior
payload. Carry must skip the fixed version and variant bits. Exhausting all 74
payload bits is an explicit failure, not a wraparound. The reference code handles
clock rollback through the same branch as equal timestamps.

### State and effect ownership

Confirmed repository design:

- Add `logseq_db_types/lib/squuid.ml` and `squuid.mli` for a pure transition over
  abstract generator state, an explicit millisecond timestamp, and supplied
  random bytes. Return the next state and UUID, or a typed error. Keep clock
  reads, entropy acquisition, and global mutation outside this module.
- Own one process-lifetime instance in `app/application.ml`, shared by direct
  captures and child captures across graph switches. Serialize generation and
  state publication as one operation. Do not create separate generators per
  editor, route, graph, or save attempt.
- Use `Journal_time.instant_unix_ms creation_time` from the successful calendar
  sample as the input timestamp. UUID generation must not perform another clock
  sample that could disagree with the command's recorded creation time.
- Supply 16 OS-random bytes and select the payload bits using the reference
  layout. The confirmed native adapter uses Unix access to `/dev/urandom`, handles
  partial reads, and closes the descriptor on every path. Verify this source on
  both supported Apple targets. Do not reuse MD5, PID, counters, or OCaml's
  non-cryptographic random generator as entropy.
- Reject negative timestamps and values above `2^48 - 1`. Validate supplied byte
  length. On entropy or generation failure, retain the draft and surface an
  actionable save error through the existing error presentation. Publish no
  create request and do not advance generator state on failure.

The pure library's `dune` stanza discovers modules automatically. The App already
depends on `logseq_db_types`, `threads`, and `unix`, so this design needs no
new library dependency or `dune` modification. Exact API names and error wiring
remain implementation details within the confirmed ownership boundaries.

### Block creation and retries

Replace only the two `~block_id:(fresh_identity ())` expressions. Generate once
when admitting a new block creation and store the resulting identity in the
existing pending command. `Journal_capture` and `Journal_detail` remain the
owners of pending creation intent; retries of that intent reuse its stored
block ID. Rejected admission may leave an unused ID; contiguous allocation is
not a requirement.

Keep mutation IDs on their current helper, since changing them is outside the
requested block identity scope. Request IDs and deterministic journal page
UUIDs also keep their existing semantics. Remove the old block-generation call
paths rather than introducing a selector, fallback, or migration. Existing and
remote UUIDs remain opaque graph identities; do not rewrite stored blocks or
restrict general UUID parsing to v8.

UUID order must not become a replacement for `block/order`, journal dates,
`creation_time`, or sync ordering. The proposal does not change the UI layout,
startup behavior, or divider count governed by `docs/ux-guidelines.md`.

### Implementation boundaries

Expected production files are the new `logseq_db_types/lib/squuid.ml` and
`squuid.mli`, plus `app/application.ml`. Identify the existing error presentation
and pending-intent behavior before deciding whether any additional App file
needs an edit. Do not modify OCaml files under `spec/`, any `dune` file, or OCaml
files in the `bonsai_flutter` repository. If the eventual implementation cannot
fit these constraints, report the concrete boundary before proceeding.

## Decision

Implemented on 2026-09-07 at the user's request.

- `logseq_db_types/lib/squuid.ml` and `squuid.mli` expose abstract immutable state,
  `empty`, and `next`, with typed timestamp-range, random-length, and payload
  exhaustion errors. State retains a timestamp and separate 12-bit and 62-bit
  payload fields, so incrementing never crosses the version or variant markers.
  Caller-owned random bytes are not retained.
- `app/application.ml` owns one module-level generator state and mutex. Entropy
  acquisition, transition, and successful state publication run under the same
  lock, independently of component creation and graph switches. The Unix reader
  uses `/dev/urandom`, completes partial reads, retries interrupted reads, rejects
  EOF, and closes the descriptor with `Fun.protect`.
- Both creation paths use `with_block_identity` with the already sampled
  `creation_time`. Its admission callback runs only after successful allocation;
  failures update the existing save-error presentation and retain the draft.
  Successful child admission clears any previous allocation error. Pending
  commands and retries remain owned by `Journal_capture` and `Journal_detail`.
- `app/application.mli` adds two `For_testing` entry points for the actual entropy
  reader and allocation/admission boundary. Tests can supply entropy without
  resetting or replacing the process-lifetime generator.
- Mutation IDs still use `fresh_identity`. No `dune` file, OCaml file under
  `spec/`, or bonsai_flutter OCaml source was changed. Existing user changes were
  preserved. UI layout, startup, and divider behavior remain unchanged.

### Validation and ownership

The pure `Squuid.next` transition owns UUID state and ordering. Its public API is
covered in the existing `test/journal_model_test.ml` target: the upstream vector,
Unix epoch zero, all variant nibbles, canonical round-tripping, later/equal/earlier
clocks, carries between payload fields, maximum timestamp, exhaustion, invalid
inputs, and immutable state after failures or caller byte mutation.

`Journal_capture` and `Journal_detail` own admitted creation intent. Existing
public reducer tests in `test/journal_routes_test.ml` now admit generated block
IDs and assert whole-command retention through failure and retry. Child failure
and retry coverage was extended at this owner only.

Entropy exceptions and serialized publication belong to the Application adapter,
not those pure pending-intent owners. The existing
`test/application_view_test.ml` target exercises the real admission wrapper with
failing entropy or invalid generation inputs, verifies zero admission callbacks,
and checks draft retention and unchanged generator state before a successful
retry. It also exercises the native reader and concurrent allocations. No UUID
transition coverage was duplicated in persistence, transport, integration, E2E,
or UI tests; no existing tests were removed.

Before implementation, the new pure tests failed with `SQUUID allocation
unexpectedly failed`; the adapter tests rejected successful allocation and
observed zero native entropy bytes using temporary unimplemented bodies. After
implementation:

- `dune exec test/journal_model_test.exe`: passed.
- `dune exec test/journal_routes_test.exe`: passed.
- `dune exec test/application_view_test.exe`: passed, all eight cases.
- `dune build @all`: passed.
- `dune runtest`: passed on rerun. The first run hit an existing transport fixture
  failure at `logseq_sync/test/transport_contract.ml:151`, consistent with the
  fixture's race between creating `ready` and writing its port contents. The isolated transport case
  42 and subsequent complete test invocation passed without changes to that
  fixture or production transport code.
- `bonsai-flutter build-native --target=macos --profile=debug`: passed complete
  object and Mach-O verification for arm64/macOS 26.0.
- `bonsai-flutter build-native --target=iphoneos --profile=debug`: passed Mach-O
  verification for arm64/iOS 15.0. The linker reported SDK GMP search-path and
  sqlite text-stub warnings; these did not prevent artifact generation.
- `sh test/test_block_entropy_apple.sh macos` and
  `sh test/test_block_entropy_apple.sh ios-simulator <booted-device-id>`: passed.
  The standalone platform probe opens `/dev/urandom`, reads exactly 16 bytes, and
  closes the descriptor without duplicating UUID tests. The iOS runtime was
  Simulator 26.1; this is platform-source validation plus iPhoneOS compilation,
  not a physical-device or app-sandbox runtime test. The temporary simulator was
  shut down and removed afterward.
- Changed OCaml files passed `ocamlformat --check`; the platform probe passed
  `sh -n`; `git diff --check` passed.
- `spec-dev-tool check --all`: passed after transition to implemented.

## Alternatives considered

### Keep the existing MD5 helper for blocks

Smallest change, but does not satisfy the requested SQUUID scheme or establish a
dedicated generation contract.

### Use only the timestamp plus independently random suffixes

Requires no retained state, but does not preserve the reference behavior when
multiple blocks are allocated within one millisecond or the clock moves back.

### Persist generator state across process restarts

Could extend local monotonicity across restarts, but introduces durable ownership
and crash recovery work beyond block allocation. The confirmed decision uses
fresh random state on each process start, with no promise of ordering across
restarts or devices.

### Change every UUID-producing path together

Would broaden the change to mutation identity and deterministic journal page
identity. The present request concerns new blocks; retain those separate
semantics and remove only obsolete block allocation paths.

## Acceptance criteria

- Direct capture and child creation both obtain new block IDs from the same
  generator owner; neither uses `fresh_identity` for a block ID.
- Deterministic public API tests verify timestamp encoding, version 8, all four
  allowed variant nibbles, canonical text, and `Graph_types.Uuid` round-tripping.
  Include the upstream example: timestamp `1640183584769` with base UUID
  `85335e1f-9c1f-4c62-9ce9-cef70883794a` produces
  `017de28f-5801-8c62-9ce9-cef70883794a`.
- Pure transition tests cover first allocation including Unix epoch zero, later
  timestamps, repeated timestamps, backward clock movement, carry across payload
  fields, maximum timestamp, payload exhaustion, and invalid input. Assert
  increasing order with the repository's public `Uuid.compare`.
- Test the public pending-intent owners for retention of a generated block ID
  across failure and retry, extending existing coverage only where needed.
  Do not regenerate IDs in persistence, transport, or overlay planning.
- Before adding any bug regression test, identify the production state owner
  and attempt reproduction through its public pure events, state, completions,
  and effects. If that boundary reproduces the issue, add only pure regression
  coverage. Do not inject an already incorrect external result or bypass `.mli`
  boundaries to claim pure reproduction.
- Verify OS entropy acquisition on macOS and iOS at the narrowest necessary
  platform boundary. Do not duplicate generator transition tests in UI, E2E,
  persistence, transport, or effect-runner suites. Use existing test targets;
  no `dune` changes are authorized by this document.
- An allocation error preserves draft content and sends no create command.
- No existing block IDs, mutation IDs, request IDs, journal page identity rules,
  sibling ordering, or visible creation-time semantics change.

## Consequences

- Monotonicity belongs to one serialized generator lifetime. Separate devices
  and restarted processes can generate IDs in a different relative order;
  uniqueness between them is probabilistic and depends on OS entropy.
- Following a backward clock adjustment, the UUID prefix reflects the retained
  logical timestamp, while `creation_time` records the actual sampled instant.
  Code must not derive user-visible creation time from a block UUID.
- Payload increment is easy to implement incorrectly around the variant and
  version positions. Boundary vectors must exercise those carries explicitly.
- SQUUID exposes a timestamp prefix. IDs are identifiers, not secret tokens.
- The new shared module is pure, but the App adapter owns entropy, synchronization,
  and recoverable failure handling. These responsibilities need one owner.
- Ordered keys may improve locality, but no performance improvement is claimed
  without measuring this repository's actual storage workload.
