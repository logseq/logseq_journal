# Derive Persistence JSON Codecs with Yojson PPX

## Problem

`logseq_overlay_db/lib/database.ml` owns the durable representation of the logical
outbox and its idempotency evidence. SQLite deliberately stores those values as
opaque text:

- `sync_outbox.record` contains one complete logical outbox record;
- `overlay_mutation_receipts.receipt` contains an applied, no-change, remote-won,
  blocked, or discarded mutation outcome;
- `overlay_terminal_batch_receipts.receipt` contains an accepted or
  proven-unexecuted submission-batch outcome.

The values must survive process restart. They preserve mutation identity,
normalized transactions, dependency shadows, delete rollback artifacts, immutable
protected bytes, transport state, `t_before`, batch membership, conflict evidence,
and terminal receipts. Removing serialization is therefore not a valid
simplification.

The accidental complexity is the amount and location of handwritten structural
JSON code. `database.ml` currently contains:

- primitive and nested ADT encoders and decoders from approximately lines
  1,438-2,006;
- the format-version-14 outbox record codec from approximately lines 2,007-2,312;
- the format-version-1 mutation receipt codec from approximately lines
  2,320-2,561;
- the format-version-1 terminal batch receipt codec from approximately lines
  2,562-2,635.

Much of this code manually performs record-field lookup, option and list traversal,
variant dispatch, and nested `Result.bind` plumbing. That boilerplate obscures the
important behavior: version enforcement, opaque-token validation, cross-field
invariants, canonicality, and fail-closed restore.

The package currently depends on `yojson` 3.0.0 but has no JSON PPX dependency or
preprocessing configuration. Introducing generated codecs therefore changes the
package build definition and dependency lock, even if it leaves runtime behavior
and the public `Logseq_overlay_db` interface unchanged.

## Proposal

Introduce a Yojson PPX only for private persistence DTOs. Do not derive codecs for
the public or internal domain records directly.

Define format-specific private DTOs for the current durable representations:

- `outbox_record_v14` and its nested mutation, transport, shadow, footprint, and
  delete-artifact DTOs;
- `mutation_receipt_v1`;
- `terminal_batch_receipt_v1`.

Use JSON-key annotations and small custom leaf converters so the DTO codecs retain
the existing camel-case keys, explicit discriminators, `null` conventions, decimal
`int64` strings, UUID strings, and versioned token strings. Generated code should
handle structural record, variant, list, and option traversal. Explicit conversion
and validation functions should continue to own:

- exact `formatVersion` acceptance;
- `Graph.Uuid`, `Server_cursor`, `Checksum`, `Submission_batch_id`, and
  `Mutation_fingerprint` construction;
- non-negative, positive, non-empty, and fixed-length bounds;
- receipt-key and payload-identity agreement;
- transport-state and submission-metadata combinations;
- mutation-specific dependency-shadow and delete-artifact constraints;
- canonical conflict ordering and every other invariant currently enforced by
  `outbox_record_is_canonical` or durable receipt validation.

The intended pipeline is:

```text
JSON string
  -> PPX-generated structural DTO decoder
  -> explicit leaf and semantic validation
  -> internal domain value
```

Encoding follows the reverse path. The current V14 outbox and V1 receipt formats
remain the only accepted and emitted formats. This change must not add an old/new
parallel decoder, migration, compatibility alias, or fallback.

Move the resulting persistence codecs out of `database.ml` into private modules
owned by `logseq_overlay_db`. `database.ml` should retain orchestration calls such
as encode-before-persist and decode-on-open, but not the field-by-field JSON
implementation. A small shared persistence JSON module may contain reusable opaque
token and bounded scalar converters when at least two codecs use them.

If selected, add the chosen PPX package to the package and workspace dependencies,
configure it in `logseq_overlay_db/lib/dune`, update generated dependency metadata,
and list every new codec module as private. No module under `spec/`, public API,
SQLite schema, UI source, or `bonsai_flutter` source should change.

Before deleting the handwritten codecs, freeze their observable behavior with
golden and corruption tests. Generated encoders must be compared with the current
canonical strings for every mutation, transport state, receipt outcome, optional
field shape, and nested delete-artifact form. Generated decoders must preserve the
current acceptance and rejection behavior for malformed types, missing values,
unknown versions, invalid opaque tokens, inconsistent identities, and
non-canonical records.

## Decision

Adopt `ppx_deriving_yojson` for private, format-specific persistence DTOs. Preserve
the current V14 outbox and V1 receipt JSON byte-for-byte, including object key
order. Convert the outbox, mutation-receipt, and terminal-batch-receipt codecs in
one atomic cutover so their shared leaf converters and validation boundary have one
owner.

Keep semantic and canonical validation explicit after generated structural decode.
Do not derive directly on domain types, change the SQLite schema or public API, or
retain handwritten and generated codecs in parallel. The user confirmed this
complete direction on 2026-09-04.

## Alternatives considered

### Extract the handwritten codecs without PPX

Move the existing functions into private codec modules without changing their
implementation. This substantially improves `database.ml` ownership and carries
the lowest format risk, but retains most of the repetitive field lookup and nested
result plumbing. It remains the fallback if generated-code behavior cannot match
the current format precisely.

### Derive directly on domain types

Add deriving attributes to `outbox_record`, `local_mutation`, receipts, and their
nested domain types. This creates the least source code, but couples the durable
format to OCaml field and constructor names. The default representation would also
change current discriminators such as `saveBlock` and `remoteWon`, opaque token
encoding, `int64` handling, and optional `null` fields. A harmless internal rename
could then become an accidental disk-format change, so this alternative is not
recommended.

### Normalize the durable values into relational columns

Replace opaque JSON text with normalized SQLite tables and columns. This could move
some structural validation into the schema, but it expands the change into storage
schema design, transaction joins, schema-version policy, and a different corruption
surface. It is not a codec simplification.

### Replace JSON with Transit or a binary format

Adopt the existing Transit ecosystem or introduce a binary serialization format.
This changes the durable representation without removing the need for explicit
versioning and semantic validation. It also makes fixtures and corruption diagnosis
less approachable. There is no current evidence that JSON parsing cost is a
performance problem, so this alternative is not recommended.

## Acceptance criteria

- `database.ml` no longer contains field-by-field JSON codecs for outbox records,
  mutation receipts, or terminal batch receipts.
- Private, format-specific persistence DTO modules own generated structural JSON
  codecs and explicit domain conversion.
- The emitted V14 outbox and V1 receipt JSON remains byte-for-byte identical to the
  frozen current output for every supported variant and optional-field shape.
- Restore preserves the current typed success and fail-closed behavior for valid,
  malformed, corrupt, unknown-version, identity-mismatched, and non-canonical
  durable data.
- Semantic and cross-field validation remains explicit and reviewable; PPX output
  is not treated as proof that a decoded domain value is valid.
- Restart preserves queued, submitted, accepted-pending-authoritative, rejection
  catch-up, blocked, retry, remote-won, no-change, discarded, and terminal-batch
  behavior.
- The SQLite schema and public `Logseq_overlay_db` specification do not change.
- No compatibility decoder, migration, fallback, or duplicate format path remains.
- The package dependency, lockfile, and Dune preprocessing declarations contain
  only the selected PPX and its required transitive dependencies.
- Codec golden tests, corruption tests, overlay storage tests, overlay Sync tests,
  package-boundary tests, `dune build @all`, `dune build @fmt`,
  `ocamlformat --check` for every changed OCaml file, `git diff --check`, and
  `spec-dev-tool check --all` pass.

## Consequences

- `database.ml` now delegates V14 outbox and V1 receipt persistence to private
  `Persistence_outbox_v14` and `Persistence_receipt_v1` modules.
- `ppx_deriving_yojson` generates structural traversal for private persistence
  DTOs, while explicit conversion code continues to validate opaque values,
  numeric bounds, identities, canonical nested objects, and cross-field state.
- The existing SQLite schema, public overlay specification, and accepted durable
  format versions remain unchanged.
- Frozen storage tests cover every local mutation JSON shape and the Applied and
  No_change receipt shapes; the existing corruption, restart, and Sync suites
  continue to exercise the remaining transport and terminal outcomes.
- The overlay package now carries the build-time PPX and its runtime support as
  exact package dependencies.

## Risks

- A generated encoder may change object key spelling, key order, variant shape,
  optional-field encoding, or integer representation. Golden byte comparisons must
  detect this before cutover.
- A generated decoder may accept unknown fields or report malformed input
  differently from the current decoder. Explicit wrapper validation and corruption
  tests must freeze the intended behavior.
- Private DTOs add a domain-to-persistence mapping layer. Poorly chosen DTO
  boundaries could replace JSON boilerplate with equally repetitive conversion
  boilerplate.
- Adding a PPX increases build-time dependency and compiler preprocessing
  complexity for a runtime path that currently needs only `yojson`.
- Generated codec behavior is tied to the selected PPX version. The dependency must
  be pinned consistently with the repository's exact package policy.
- The current implementation interleaves representation checks with semantic
  checks. Extraction may accidentally omit an invariant unless tests enumerate the
  accepted and rejected forms before the rewrite.
- Byte-for-byte compatibility constrains how much of the encoder can be generated;
  a few explicit envelope or leaf codecs may remain preferable to fragile PPX
  customization.

## Questions

- Resolved on 2026-09-04: use `ppx_deriving_yojson`.
- Resolved on 2026-09-04: preserve emitted JSON byte-for-byte, including object key
  order.
- Resolved on 2026-09-04: convert the outbox and both receipt codec families in one
  atomic cutover.
