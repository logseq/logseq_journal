# Collapse Overlay Database Workflow Wrappers

## Problem

`logseq_overlay_db/spec/database.mli` still exposes several one-use values and
phase transitions after the durable-mirror surface was simplified by
`docs/agent-guide/implemented/simplification/2026-09-03-collapse-durable-mirror-lifecycle-wrappers.md`.
The current implementation and call graph now provide stronger evidence than the
first-cut architecture document that selected those interfaces.

The supported in-repository production path has one consumer:
`logseq_db_worker/lib/effect_runner/effect_runner.ml`, with construction in
`logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml`. The overlay tests and
benchmark are non-production consumers. The package is installable, so unknown
out-of-tree consumers may exist, but repository policy explicitly does not preserve
backward compatibility and requires obsolete paths to be removed rather than kept
as adapters.

The remaining accidental complexity falls into four related wrapper chains.

### Construction validates the same limits through two values

`Database.limits` validates a record whose concrete representation is already the
public `Types.capability_limits` record, then `Database.dependencies` immediately
wraps that value with two clocks. Production constructs the two values back to back
and unwraps two `Result`s. `Database.dependencies` currently returns `Ok`
unconditionally, so `Types.dependencies_error = Invalid_dependencies of string`
has no implementation path.

`delete_mirror` and `collect_garbage` also accept `dependencies`, but their
implementations name the argument `_dependencies` and never use a clock or limit.
The generation-carrying `mirror_inspection` already contains everything those
closed-mirror operations need.

### Local preparation repeats work without an external phase

The only production caller invokes `prepare_local` and immediately invokes
`commit_local`. Nothing observable or effectful happens between the two calls.
`prepare_local` acquires the database mutex, validates identity and preconditions,
reads the clock, plans the complete effect, calculates delete artifacts, and checks
admission. `commit_local` then enters the serialized commit lane, reacquires the
mutex, checks identity and preconditions again, and calls `planned_effect` again
before persistence.

The public `prepared_local` value exposes no plan, crypto request, or other work for
a caller to perform. `cancel_local` has no production, test, tool, or benchmark
consumer and only sets a boolean on an in-memory record; it releases no lease,
storage handle, staging directory, lock, or other resource. The split therefore
adds `prepared_local`, `local_preparation`, `prepare_local`, `cancel_local`, two
error types, duplicated caller branches for `Existing_mutation`, and repeated
planning while providing no retained feature.

### Crypto result wrappers are constructed only to be handed back

`protected_values` and `decrypted_values` are opaque wrappers around an originating
request plus its returned strings. Every production use has the same shape:

```text
request -> request accessor -> external crypto -> validated result constructor
        -> the one owning supply/finish operation
```

The result constructors validate item identity, cardinality, order, size, staleness,
and cancellation. The consuming operation then checks physical request identity
again. No production or non-production caller retains a validated result, routes it
to another subsystem, or consumes it more than once. The owning preparation already
retains the exact request, so validation can occur once in the operation that
consumes the returned strings. Request values and correlation IDs must remain
opaque and bounded; the extra result objects need not remain public.

### Sync finish tokens have no independent public lifetime

The outbox path exposes
`prepared_outbox_transition -> prepared_outbox_commit`, and the authoritative path
exposes `authoritative_preparation -> prepared_authoritative_commit`. In both
production paths, the finish result is immediately passed to commit. Neither
finished value is stored, shared, or subjected to another external operation.

`cancel_outbox_commit` and `cancel_authoritative_commit` have no repository
consumers and only set a boolean. `cancel_outbox_transition` and
`cancel_authoritative` are called only when synchronous crypto fails, immediately
before the preparation goes out of scope; they also release no external resource.
The public examples are more defensive than production by wrapping both phase
values in `Fun.protect`, but the implementation still relies on mutable
consumed/canceled flags because OCaml values are not linear capabilities.

The already-implemented snapshot simplification is the relevant precedent. It
removed `prepared_snapshot_commit` and `finish_snapshot_activation`, retained one
private runtime state machine, and kept only the cancellation that actually removes
staged files. Outbox and authoritative preparations own only ordinary in-memory
data. Their stale Sync token, generation, closed-database, size, integrity, and
durability checks are necessary; their additional public phase objects are not.

## Proposal

Collapse the remaining single-consumer wrappers into the operations that own their
validation or durable effect. Preserve all necessary logical, synchronization,
cryptographic, durability, ordering, and semantic error distinctions, while
removing cancellation and phase errors that exist only for deleted in-memory
wrappers.

### Validate public capability limits at dependency construction

Remove abstract `Database.limits`, the `Database.limits` function, and
`Types.dependencies_error`. Continue to expose `Types.capability_limits` because it
is already the limits DTO returned by `graph_info`, and validate that record in
`Database.dependencies` before constructing the opaque dependencies value:

```ocaml
val dependencies
  :  epoch_ms:(unit -> int64)
  -> monotonic_ns:(unit -> int64)
  -> limits:Types.capability_limits
  -> (dependencies, Types.limits_error) result
```

Retain every current positive-bound and
`wire_batch_max_bytes <= outbox_max_bytes` check. Remove the unused `dependencies`
argument from `delete_mirror` and `collect_garbage`; keep their mirror-generation
reinspection, exclusive ownership, and operation-specific results and errors
unchanged.

### Commit local mutations as one serialized operation

Remove `prepared_local`, `local_preparation`, `prepare_local`, and `cancel_local`.
Make `commit_local` accept the mutation and existing opaque `write_precondition`
directly:

```ocaml
val commit_local
  :  t
  -> expected:write_precondition
  -> Types.local_mutation
  -> (Types.local_commit_outcome, Types.local_commit_error) result
```

Perform identity lookup, required-precondition validation, target-revision checks,
clock capture, effect planning, delete-artifact freezing, admission, persistence,
projection publication, and receipt creation once inside the serialized operation.
The same mutation ID and fingerprint must still return `Local_existing`, a
different fingerprint must still fail, and concurrent callers must still produce
at most one durable outcome and one logical change. Merge the non-overlapping cases
of `Types.local_prepare_error` into `Types.local_commit_error`; remove only the
consumed, canceled, and preparation-generation cases that cannot exist without a
public preparation.

Keep `write_precondition` and its validated constructor. It is shared by
`commit_local` and `retry_blocked`, and duplicate target entries are a genuine
ambiguous request rather than preparation-phase machinery.

### Validate crypto output at its consuming operation

Remove `protected_values`, `decrypted_values`, and their two public constructor
functions. Retain `protection_request`, `unprotection_request`, both request
accessors, `Types.crypto_item_id`, and the applicable
`Types.crypto_result_error` cases. Remove `Crypto_result_canceled`, because only
the deleted in-memory outbox and authoritative cancellation functions set the
request-level canceled flags; snapshot abandonment remains represented by
`Snapshot_preparation_canceled`.

For snapshot batches, pass the originating request and plaintexts directly to the
existing supply operation:

```ocaml
val supply_snapshot_unprotection_batch
  :  prepared_snapshot_activation
  -> request:unprotection_request
  -> plaintexts:(Types.crypto_item_id * string) list
  -> (unit, Types.snapshot_activation_error) result
```

For outbox and authoritative work, pass an optional pair of the exact request and
returned items to the final operation. The implementation must run the existing
`Crypto_bridge.validate_results` checks before decoding, staging, sizing, or
durability. Add an operation-specific wrapper case around
`Types.crypto_result_error` in each owning workflow error so missing, extra,
duplicate, reordered, stale, and oversized results remain typed and
distinguishable. Snapshot cancellation continues to reject the outstanding request;
outbox and authoritative preparations no longer manufacture a canceled request
state after their in-memory cancellation APIs are removed.

### Use one preparation and one final operation per Sync direction

Retain a begin step because external encryption or decryption must occur outside
`Database`, but remove the finish step and second prepared-commit type.

The outbox flow becomes:

```ocaml
val begin_outbox_transition
  :  t
  -> expected:Types.sync_token
  -> Types.outbox_transition
  -> ( prepared_outbox_transition * protection_request option
       , Types.outbox_transition_error )
       result

val apply_outbox_transition
  :  t
  -> prepared_outbox_transition
  -> encrypted:
       (protection_request * (Types.crypto_item_id * string) list) option
  -> (Types.outbox_commit, Types.outbox_transition_error) result
```

`apply_outbox_transition` performs the current finish validation and atomic commit
in one call. Merge `Types.outbox_prepare_error` and
`Types.outbox_commit_error` into `Types.outbox_transition_error` without collapsing
distinct error cases.

The authoritative flow becomes:

```ocaml
type authoritative_application =
  | Authoritative_applied of Types.authoritative_commit
  | Authoritative_deferred of Types.authoritative_defer

val begin_authoritative
  :  t
  -> expected:Types.sync_token
  -> Types.authoritative_batch
  -> ( authoritative_preparation * unprotection_request option
       , Types.authoritative_transition_error )
       result

val apply_authoritative
  :  t
  -> authoritative_preparation
  -> decrypted:
       (unprotection_request * (Types.crypto_item_id * string) list) option
  -> (authoritative_application, Types.authoritative_transition_error) result
```

`apply_authoritative` performs the current decode, origin validation, delete
classification, overlay replan, staging, and atomic commit. It returns the existing
defer reason when a submitted delete still awaits its terminal transport outcome.
Merge `Types.authoritative_prepare_error` and
`Types.authoritative_commit_error` into one workflow error while preserving every
current semantic case.

Remove `prepared_outbox_commit`, `prepared_authoritative_commit`,
`authoritative_finish`, `finish_outbox_transition`, `finish_authoritative`, both old
commit functions, and all four outbox/authoritative cancellation functions. A
preparation abandoned before its final operation is ordinary unreachable memory;
the GC is its cleanup. This intentionally removes explicit invalidation of a
retained in-memory preparation because there is no independent owner or resource to
cancel; stale-token, consumed-value, generation, and closed-database checks still
reject invalid application attempts. The private final operations may retain
internal intermediate records, but must not recreate public or caller-visible phase
tokens.

This cutover is expected to remove six abstract public types (`limits`,
`prepared_local`, `protected_values`, `decrypted_values`,
`prepared_outbox_commit`, and `prepared_authoritative_commit`), one local result
variant, at least nine public functions, and four phase-specific error types. It
also removes the second local planning pass and the caller's duplicate handling of
an existing mutation. No compatibility aliases, deprecated functions, or fallback
paths are retained.

### Preserve boundaries with independent behavior

The following remain unchanged in concept:

- `mirror_inspection` and `mirror_presence`, because the former carries a private
  location and generation capability while the latter is caller-visible metadata;
- `prepared_snapshot_activation` and `cancel_snapshot_activation`, because the
  preparation owns a staging directory that must be removed when abandoned;
- `snapshot`, `release_snapshot`, `subscription`, `activate_subscription`,
  `unlisten`, `t`, and `close`, because they own coherent roots, queued events,
  callbacks, storage, or exclusive graph ownership;
- the separate block, page, journal, and structure reads, because their result
  records and domain meanings differ even when their pagination mechanics overlap;
- the paused `listen`/`activate_subscription` boundary, because it prevents a real
  hydration/listen race;
- Sync compare-and-set tokens, projection and entity revision tokens, generation
  fences, request correlation IDs, bounded batches, immutable submitted bytes,
  authoritative continuity/checksum checks, and atomic persistence;
- `inspect_admission`, `retry_blocked`, and `discard_blocked`, despite having no
  current production caller, because they implement distinct admission and blocked
  mutation recovery behavior required by the accepted overlay lifecycle.

Implementation scope is limited to the overlay specification and implementation,
the Worker Effect Runner and Bonsai constructor, public-boundary assertions, overlay
and Worker tests, the benchmark, and directly affected English documentation. No
Dune file, generated source, UI source, or `bonsai_flutter` source should change.

## Decision

Adopt the complete wrapper collapse as one atomic public-API cutover. The cutover
includes validated dependency construction, one-step local commit, direct
crypto-result consumption, and one final operation per Sync direction. Every
behavior and safety boundary explicitly retained by this document remains required.

The user confirmed this complete scope on 2026-09-04. No partial compatibility
surface, deprecated wrapper, or old/new parallel path is part of the decision.

## Alternatives considered

### Keep type-state wrappers for documentation

This is the strongest reason to retain the current design: distinct OCaml types make
the intended begin/finish/commit order visible and prevent passing an unfinished
value to a commit function. They do not, however, provide linear ownership. The
implementation still carries mutable consumed/canceled flags, request identity
checks, Sync revision checks, and generation checks. The only production caller
follows each chain immediately, and the current snapshot workflow already preserves
retry and atomicity with one opaque preparation. Documentation and one private state
machine retain the useful order without requiring every caller to coordinate the
phases.

### Keep local planning outside the commit operation

This would preserve a possible future UI preview or asynchronous approval step, but
`prepared_local` exposes no preview data and no current caller performs work between
prepare and commit. The implementation already plans under the database mutex and
then repeats the plan at commit. A future preview feature should introduce an API
that exposes its actual semantics rather than preserve an unused phase today.

### Pass crypto callbacks into monolithic operations

Rejected. It would reduce request types too, but cryptographic execution and graph
keys belong to Sync. Explicit opaque requests keep Database free of crypto effects
and allow the Worker to use its platform implementation. The proposal removes only
the validated-result wrapper, not the external-crypto boundary.

### Merge all read APIs into one request/result ADT

Rejected. `get_blocks`, `get_pages`, `get_journals`, and `get_structure` have
different result shapes and caller intent. One union would replace clear functions
with request/result coupling and exhaustive irrelevant cases without removing a
domain concept.

### Remove every public operation without a production caller

Rejected. Reference count is not sufficient evidence. `inspect_admission` computes
real dynamic capacity information, and `retry_blocked`/`discard_blocked` implement
required recovery transitions. `collect_garbage` is different: its current
implementation has no production caller and always reports `reclaimed_bytes = 0L`,
so its name promises behavior it does not provide. Removing or implementing that
capability is a separate feature/architecture decision rather than part of this
wrapper-only simplification.

### Unify every operation error into one database error

Rejected. A single broad error type would permit impossible cases at most call
sites and weaken useful domain ownership. The proposal merges errors only when the
corresponding public phases are merged, retaining distinct local, snapshot, outbox,
authoritative, read, listen, open, close, and maintenance contracts.

## Acceptance criteria

- `logseq_overlay_db/spec/database.mli` no longer exposes the six listed wrapper
  types, the local preparation result, or any removed constructor, finish, commit,
  or cancellation function.
- `Database.dependencies` validates the existing public capability-limits record
  and is the only construction result; every current limit invariant is preserved,
  and no unreachable `Types.dependencies_error` remains.
- `delete_mirror` and `collect_garbage` require only their current
  `mirror_inspection` and preserve generation reinspection, ownership exclusion,
  results, and errors.
- One `commit_local` call preserves mutation validation, target-local
  preconditions, deterministic clock capture, delete frontier and footprint
  freezing, admission, idempotent same-ID outcomes, atomic persistence, exact
  projection revision behavior, and at-most-one logical change under concurrency.
- Local planning occurs once per commit attempt; no private replacement
  preparation record, canceled flag, or duplicated existing-mutation branch remains.
- Snapshot, outbox, and authoritative crypto output still rejects missing, extra,
  duplicate, reordered, foreign, stale, and oversized values before any decoded or
  durable state can observe them; snapshot cancellation also continues to reject
  its outstanding request.
- Encryption and decryption remain external to `Database`, and only opaque bounded
  requests and `(crypto_item_id * string) list` values cross the boundary.
- Outbox application preserves exact submission grouping, dependency eligibility,
  immutable protected bytes, retry bytes, batch identity, `t_before`, transport
  state, logical activity, Sync revision, persistence, and publication behavior.
- Authoritative application preserves cursor continuity, checksum and origin
  validation, deferred submitted-delete handling, remote-wins proofs, queued-only
  replan, blocked outcomes, checkpoint advancement, atomic persistence, and logical
  publication behavior.
- Failed validation and persistence preserve the current retryability or consumed
  semantics for each workflow even though those states are private. No abandoned
  in-memory preparation requires explicit cleanup; snapshot staging remains
  explicitly cancelable and tested for artifact removal.
- The sole production consumer contains no immediate local prepare/commit branch,
  crypto result constructor, finish/commit chain, or inert cancellation call.
- Public-only tests cover the retained success, conflict, stale-token, replay,
  correlation, bounds, cancellation, failure atomicity, and concurrency behavior.
- `dune runtest logseq_overlay_db/test`, `dune runtest logseq_db_worker/test`,
  `dune runtest test`, `dune build @all`, `dune build @fmt`,
  `ocamlformat --check` for every changed OCaml file, `git diff --check`, and
  `spec-dev-tool check --all` pass.

## Risks

- A single final Sync operation hides the decode/plan-versus-durable-commit phase
  boundary from the caller. Private code must avoid holding the commit lane while
  performing unnecessary pure work and must recheck the Sync token immediately
  before persistence.
- Local planning moves into the serialized operation. This removes duplicate work,
  but targeted concurrency and performance tests must prove that dispatch capacity,
  lock ordering, and responsiveness do not regress.
- Merging workflow error types requires updating exhaustive pattern matches. Exact
  semantic error cases must remain available even though phase names disappear.
- Direct crypto-result consumption moves validation errors into the owning workflow
  result. Tests must assert exact nested crypto errors rather than accepting a
  generic decode or preparation failure.
- Removing outbox and authoritative cancellation intentionally gives up explicit
  invalidation of an otherwise retained in-memory preparation. Known callers do not
  retain or share those values, and all stale, consumed, generation, and database
  state checks remain enforced at application.
- The public package is source-incompatible after the cutover. Known consumers can
  be updated atomically; unknown out-of-tree users receive no compatibility layer
  under repository policy.

## Consequences

- Dependency construction now validates the public capability-limits record in one
  call, while closed-mirror maintenance depends only on its generation-bound
  inspection.
- Local mutations validate, plan, persist, and publish through one serialized
  `commit_local` call, eliminating the unused public preparation and its duplicate
  planning pass.
- Snapshot, outbox, and authoritative workflows validate raw crypto results inside
  their owning operations while preserving exact correlation, ordering, staleness,
  and size errors.
- Sync keeps one begin step for external cryptography and one final apply step per
  direction. Abandoned outbox and authoritative preparations need no cleanup;
  snapshot cancellation remains because it owns filesystem staging.
- The Worker, tests, and benchmark use only the collapsed interface. The removed
  wrappers and phase functions have no aliases or compatibility paths.

## Questions

- Resolved on 2026-09-04: adopt the complete atomic public-API cutover, including
  one-step local commit and one final operation per Sync direction, while retaining
  every enumerated behavior and safety check.
