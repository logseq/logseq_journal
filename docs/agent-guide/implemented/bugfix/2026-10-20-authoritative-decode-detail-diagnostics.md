# Authoritative Decode Detail Diagnostics

## Problem

Build 50 classifies the phone failure as Authoritative_decode_failed but loses
which preparation, decoding or in-memory application step failed. The existing
string includes raw Transit, exception and potentially graph-specific content,
so simply displaying it would leak data and still mislabel application exceptions.

## Decision

Keep the protected Authoritative_decode_failed of string interface and all sync
behavior. Add a shared, strictly validated bounded diagnostic codec in ordinary
logseq_db_types sources. Only fixed stages, reasons, type/operation/attribute
allowlists and nonnegative bounded structural counters may cross this carrier.
Codec functions keep their current signatures; authoritative decoding emits
safe records, database adds stage/transaction context, and runner/reducer/service
propagate only validated records into Last error and Worker errors. Legacy or
invalid carriers retain the existing generic category, never arbitrary text.

Catch Datascript.with_tx exceptions as application-exception plus a fixed
exception constructor class. Do not inspect exception strings to guess causes.
An unresolved lookup ref can be visible only as a structural lookup-reference
count, not a fabricated precise failure reason or failing operation index.
Do not repair empty transactions, cursor races, retries, or recovery.

The pure reducer cannot originate wire decoding errors: its public events carry
already completed effects. Previous public runner/database reproductions reached
both preparation and application failures. Extend that narrow producer suite;
service projection tests independently verify its actual sanitizing boundary.
No private module access, protected spec or Dune changes are required.

## Alternatives considered

### Expose raw lower errors or extend protected variants

Rejected: raw errors can contain user values and paths. Extending protected specs
requires separate explicit authorization and is unnecessary with a strict safe
codec over the existing string carrier. Exception-message substring guessing
would falsely imply a known cause and is excluded.

## Acceptance criteria

- Actual wire decoding failures distinguish preparation, decode and application
  stages, fixed reasons, transaction/operation position and useful safe types.
- Last error and Worker errors preserve the same safe detail. Legacy/malicious
  diagnostic inputs cannot display arbitrary content or malformed counters.
- Synthetic boundary cases cover empty/invalid transactions, operations/fields,
  protected values, entity/reference/source-tx/numeric types, missing lookups and
  application exceptions. Tests assert checkpoint and data remain uncommitted.
- Full build/tests and independent review pass before building a correct signed
  iphoneos artifact, backing up Build 50 data and installing an in-place update.
- No raw payload, plaintext, UUID, account/graph names, token, custom attribute,
  original exception string, protected spec or Dune change is introduced.

## Risks

- Application exceptions remain intentionally broad because the public API does
  not identify their failing operation or expose typed cause information.
- Historical raw strings must fail closed to a generic diagnostic.
- Host-restamped device builds remain cross_abi_validated=false; USB launch does
  not prove complete ABI/runtime acceptance or the original incident cause.

## Questions

- None. The user explicitly approved diagnostic detail and iPhone update on
  2026-10-20. Independent review is requested; no PR, push or merge is authorized.

## Consequences

A shared abstract diagnostic codec restricts the existing string carrier to
bounded fixed enums and structural counters; unknown or malformed carriers are
never displayed. Both Last error and Worker errors use its safe formatter.
Preparation, operation decode and transaction application retain distinct stages.
Codec failures retain 1-based transaction/operation context and finite type,
operation and builtin-attribute descriptors. Custom names become custom/other.
Application exceptions retain only a fixed constructor class and bounded
best-effort lookup-reference/operation counts, never an operation attribution.
The original recursive exception fallback remains nonfatal with unknown decode
classification. Protected spec, Dune and transaction acceptance branches remain
unchanged; no empty-transaction, cursor-race or retry fix was made.

The actual runner/database producer suite now has 22 deterministic cases,
including preparation/decode/application failures, second transaction/operation
position, CAS expected/value, numeric/ref types and bounded statistics. It checks
Last error, emitted signal, unchanged checkpoint and exclusion of synthetic
content, paths, UUID and raw application exception text. Service tests cover the
real row projection, unknown/duplicate/malformed/oversized fields, invalid enums
and counters, legacy raw input, byte budget and roundtrip. No private module or
protected interface was opened for tests. The first full build and runtest pass
21 Alcotest suites / 996 cases plus standalone programs; final verification after
preserving the recursive catch is recorded externally before packaging.

Independent review found and corrected a test-only cursor fixture regression,
CAS expected-field attribution, potentially unbounded diagnostic statistics, and
the original recursive catch scope. The public interfaces cannot deterministically
induce every unexpected recursive exception or decrypt-count mismatch; these
are not claimed individually reproduced. The actual phone subtype remains to
be observed in the next installed diagnostics build, not inferred from fixtures.
Installation evidence and final hashes remain in this task's external evidence.
