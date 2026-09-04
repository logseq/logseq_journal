# Collapse Durable Mirror Lifecycle Wrappers

## Problem

The first `Logseq_overlay_db.Database` cutover intentionally exposed every durable
mirror lifecycle step as an opaque public value. The implemented API now contains
four adjacent one-shot wrapper chains:

```text
mirror_location -> inspect_mirror
mirror_inspection -> attachment -> open_
snapshot_artifact -> prepare_snapshot_activation
prepared_snapshot_activation -> prepared_snapshot_commit -> commit_snapshot_activation
```

The implementation and the only production consumer show that the intermediate
values do not have independent lifetimes or policy owners:

- `logseq_db_worker/lib/effect_runner/effect_runner.ml` constructs a
  `mirror_location` and immediately inspects it. It constructs an `attachment` and
  immediately opens it. It constructs a `snapshot_artifact` and immediately
  prepares it. It finishes a snapshot activation and immediately commits it.
- `mirror_location` contains only the private canonical path and graph UUID.
  `inspect_mirror` is its only public consumer.
- `attachment` contains only an inspection and display name. `open_` is its only
  public consumer, and `attachment` performs only the absent-mirror and blank-name
  checks that `open_` must enforce anyway.
- `snapshot_artifact` contains only the four arguments consumed by
  `prepare_snapshot_activation`; it is neither persisted nor shared with another
  subsystem.
- `prepared_snapshot_commit` contains a consumed preparation plus metadata already
  derived by `finish_snapshot_activation`. Its only public operation is commit or
  cancel. The production consumer does not retain it or retry it separately.
- `Types.snapshot_activation_commit` duplicates graph UUID, checkpoint, and mirror
  generation from the fresh available `mirror_inspection`; only checksum is not
  currently present in `Types.mirror_presence`. Production discards the receipt.

The public surface therefore makes one production operation coordinate five
abstract wrapper types, five smart constructors or phase transitions, two cancel
functions, three phase-specific error types, and a duplicate success DTO without
providing a second production use for those boundaries. This is accidental
coordination complexity in the worker and public specification rather than a
feature of durable staging, cryptographic separation, atomic publication,
generation fencing, or exclusive ownership.

The implemented
`docs/agent-guide/implemented/architecture/2026-09-01-logseq-overlay-db-package.md`
explicitly selected this first-cut public surface, so changing it requires a new
decision. The stronger evidence now available is the completed implementation and
its actual production call graph. Repository policy does not require backward
compatibility; obsolete paths should be removed rather than retained as adapters.

## Proposal

Collapse the one-shot wrappers into the operations that own their validation and
side effects while preserving all current lifecycle behavior.

### Inspect directly from canonical identity

Remove public `mirror_location` and `mirror_location`. Make `inspect_mirror` accept
`application_support_directory` and `graph_id` directly. Canonical path derivation
remains private in `Database`, and `mirror_inspection` continues to retain the
private location for generation-fenced open, delete, garbage collection, and
activation.

`inspect_mirror` does not need `dependencies`: the current implementation ignores
that argument. Internal reinspection should call a private helper over the retained
location.

```ocaml
val inspect_mirror
  :  application_support_directory:string
  -> graph_id:Graph.Uuid.t
  -> (mirror_inspection, Types.mirror_error) result
```

### Open an inspection directly

Remove public `attachment`, `attachment`, and `Types.attachment_error`. Pass
`graph_name` and `mirror_inspection` directly to `open_`. Move the existing absent
mirror and blank graph-name rejections into `Types.open_error`; preserve ownership
acquisition, current-generation reinspection, and `Attachment_stale` behavior.

```ocaml
val open_
  :  sw:Eio.Switch.t
  -> dependencies
  -> mirror_inspection
  -> graph_name:string
  -> (t, Types.open_error) result
```

### Prepare directly from snapshot inputs

Remove public `snapshot_artifact`, `snapshot_artifact`, and
`Types.snapshot_input_error`. Pass `path`, cursor, checksum, and expected row count
to `prepare_snapshot_activation`. Perform the existing absolute-path,
single-linked-regular-file, nonnegative-row-count, checksum, and row validations
before acquiring or mutating staging resources. Retain the individual error
constructors under the snapshot activation error contract.

```ocaml
val prepare_snapshot_activation
  :  dependencies
  -> mirror_inspection
  -> path:string
  -> applied_server_cursor:Types.server_cursor
  -> expected_checksum:Types.checksum option
  -> expected_rows:int
  -> (prepared_snapshot_activation, Types.snapshot_activation_error) result
```

### Make activation one public preparation and one public commit

Remove public `prepared_snapshot_commit`, `finish_snapshot_activation`, and
`cancel_snapshot_commit`. Make `commit_snapshot_activation` finish persistence in
the staging area and then atomically publish it. Keep the private preparation state
machine so a failed publication remains retryable and the one
`cancel_snapshot_activation` operation releases every uncommitted phase.

Merge `Types.snapshot_prepare_error` and `Types.snapshot_commit_error` into
`Types.snapshot_activation_error` without removing the existing distinct error
cases. Preserve these invariants:

- snapshot parsing, row validation, checksum validation, and optional plaintext
  materialization occur only in the staging directory;
- cryptography remains caller-owned through the existing bounded request/result
  loop;
- publication remains a single atomic rename after storage is closed;
- the active location is revalidated as absent immediately before publication;
- duplicate commit, stale commit, canceled preparation, and persistence failure
  remain distinguishable;
- every uncommitted state is explicitly cancelable.

```ocaml
val commit_snapshot_activation
  :  prepared_snapshot_activation
  -> (mirror_inspection, Types.snapshot_activation_error) result

val cancel_snapshot_activation : prepared_snapshot_activation -> unit
```

Extend the available branch of `Types.mirror_presence` with the current checksum
and return only the fresh inspection from activation. This folds
`Types.snapshot_activation_commit` into the single authoritative mirror metadata
view without deleting any receipt field:

```ocaml
type mirror_presence =
  | Absent of { generation : mirror_generation }
  | Available of
      { generation : mirror_generation
      ; graph_uuid : Graph.Uuid.t
      ; checkpoint : server_cursor
      ; checksum : checksum option
      }
```

### Retain boundaries that own independent policy

Do not merge:

- `mirror_inspection` with `Types.mirror_presence`: the abstract inspection must
  retain the private canonical location and generation capability while callers
  still need a pure branch projection.
- `unprotection_request`, `unprotection_ciphertexts`, `decrypted_values`, or
  `supply_snapshot_unprotection_batch`: these bind exact, ordered, bounded crypto
  results to both snapshot activation and authoritative synchronization.
- `delete_mirror` and `collect_garbage`: they have different destructive effects,
  results, and operational intent despite sharing freshness and ownership checks.
- `open_` and `close`: they delimit the independently observable ownership and
  resource lifetime of an open logical database.

The expected net public deletion is four abstract types (`mirror_location`,
`attachment`, `snapshot_artifact`, and `prepared_snapshot_commit`), one duplicate
success DTO (`Types.snapshot_activation_commit`), five functions
(`mirror_location`, `attachment`, `snapshot_artifact`,
`finish_snapshot_activation`, and `cancel_snapshot_commit`), and three obsolete
error types (`Types.attachment_error`, `Types.snapshot_input_error`, and
`Types.snapshot_commit_error`, with their cases retained in owning operation error
types). No compatibility wrappers or deprecated aliases are retained.

## Decision

Adopt the proposal. `Database` exposes direct mirror inspection, direct opening,
direct snapshot preparation, and one commit operation over the original snapshot
preparation. The implementation retains canonical location data and activation
phase state privately, moves all lifecycle errors to the operations that own them,
and returns the fresh mirror inspection as the sole activation result.

## Alternatives considered

### Keep the first-cut public surface

This preserves the explicit type-level narrative selected by the overlay package
architecture decision. It was not selected for this proposal because the
implemented values are not linear capabilities in OCaml: callers can retain the
old preparation after finish, and runtime consumed/canceled flags already enforce
temporal validity. The extra public types therefore document phases but do not
provide stronger exclusivity than one opaque runtime-checked preparation.

### Expose absent and available inspection capabilities as separate types

An `Absent of absent_mirror | Available of available_mirror` public result could
make activation and opening eligibility statically explicit. It is not selected
because it adds public types and conversion obligations instead of simplifying the
surface, while temporal generation freshness still requires runtime revalidation.

### Pass a decrypt callback into one monolithic activation function

This would remove the request/result loop but is rejected because the database
must not own cryptographic execution or graph keys. The typed bounded correlation
protocol is shared with authoritative synchronization and encodes a real trust
boundary.

### Merge delete and garbage collection behind a maintenance action variant

This only replaces two clear functions with an action ADT and a union result. It
does not remove an operation, state, or policy and makes destructive intent less
visible at call sites.

### Return only the current activation receipt

Keeping `Types.snapshot_activation_commit * mirror_inspection` preserves duplicate
metadata and two sources of truth. Returning only the receipt would lose the
private canonical location required by later opening. Extending available presence
with checksum and returning only the fresh inspection preserves every field and
the capability needed by the next operation.

## Acceptance criteria

- The public `Database` specification contains no `mirror_location`, `attachment`,
  `snapshot_artifact`, `prepared_snapshot_commit`, or duplicate
  `snapshot_activation_commit` type.
- Mirror inspection still derives exactly the same canonical path, verifies graph
  UUID and checkpoint metadata, and returns the same absent/available distinction.
- Open still rejects absent mirrors, blank graph names, stale generations, and
  ownership conflicts before exposing `Database.t`.
- Snapshot preparation preserves every current input, row, schema, identity,
  checksum, crypto-batch, ordering, size, and stale-absence validation.
- Snapshot commit persists only in staging before atomically publishing, returns a
  fresh available inspection containing graph UUID, checkpoint, checksum, and
  generation, and supports safe retry after publication failure.
- One cancellation API releases staging resources from every uncommitted phase;
  cancel and commit remain idempotence-checked.
- Snapshot crypto execution remains outside `Database`; foreign, stale,
  incomplete, duplicate, reordered, and oversized results remain rejected.
- Delete and garbage collection continue to require a current available inspection
  and exclusive closed-mirror ownership.
- The worker effect runner contains no immediate constructor/consumer wrapper
  chains for location, attachment, artifact, or finished commit.
- Public-only overlay storage and concurrency tests cover every retained rejection,
  retry, cancellation, atomic publication, generation fencing, and ownership
  invariant.
- `dune build @all`, `dune runtest`, and `ocamlformat --check` pass for all changed
  OCaml files.

## Risks

- Consolidating errors changes which phase owns input and publication failures.
  Exhaustive callers must be updated, while every semantically distinct error case
  must remain available.
- A single opaque preparation makes the post-finish phase less visible in the
  public type graph. The private phase machine and documentation must make commit
  retry and cancellation semantics explicit.
- Adding checksum to every available inspection performs or exposes one additional
  metadata projection on warm inspection. It must use the already-read checkpoint
  metadata rather than add another SQLite read.

## Consequences

- Production callers no longer construct or immediately consume lifecycle wrapper
  values for locations, attachments, snapshot artifacts, or finished snapshot
  commits.
- Snapshot activation retains one cancelable preparation across parsing,
  cryptographic unprotection, staging persistence, publication retry, and atomic
  activation.
- Available mirror inspections now contain checksum metadata read from the same
  checkpoint record as graph UUID and server cursor.
- The public API is intentionally source-incompatible with the first-cut package;
  no deprecated aliases, adapters, or compatibility constructors remain.
- `logseq_overlay_db` is a public standalone package. Repository search found only
  the worker as a production consumer, but consumers outside this worktree cannot
  be inventoried. Repository policy explicitly chooses removal over compatibility
  layers, so the cutover must be atomic across known consumers and documentation.
- The worktree currently contains the uncommitted overlay package cutover and many
  unrelated user-owned changes. Any later implementation must preserve those
  changes and restrict edits to the exact specification, implementation, worker,
  tests, and decision-document surfaces required by this decision.

## Questions

- None. Adopt all four wrapper collapses and the activation-receipt fold as one
  atomic public-API cutover.
