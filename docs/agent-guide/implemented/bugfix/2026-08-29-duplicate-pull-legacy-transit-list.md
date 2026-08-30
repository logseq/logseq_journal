# Duplicate Pull Legacy Transit List

## Problem

The deployed graph history contains normalized transactions whose top-level
Transit collection is encoded as a list. `Pure_tx.parse` accepts only a Transit
array, so replay rejects those otherwise valid ordered operation collections.

A `pull/ok` whose server cursor equals the durable applied cursor is a duplicate.
The reducer currently scans and decodes every authoritative transaction wire
before classifying that pull as `Pull_duplicate`. A duplicate response can
therefore fail on historical or malformed transaction bodies even though none of
those transactions will be applied.

## Proposal

Treat non-empty top-level Transit arrays and lists as normalized ordered
transaction collections. Continue requiring every operation inside the collection
to use the existing operation-array representation.

After validating pull cursor continuity, exclude authoritative transaction wires
from protected-value discovery and transaction decoding when the response cursor
equals the durable applied cursor. Preserve outbox acknowledgement cleanup and
projection processing for the duplicate response.

## Decision

Accept both `Transit.Array` and `Transit.List` as non-empty top-level normalized
transaction collections while retaining array-only operation entries. Store the
validated authoritative wires in the internal authoritative plan, using an empty
wire list for a pull whose server cursor equals the durable applied cursor.

## Alternatives considered

### Accept lists only while replaying deployed history

This would introduce graph-history-specific policy outside the transaction codec.
Transit collection semantics belong at the codec boundary and should not depend on
the source graph or cursor.

### Decode duplicate transactions and suppress their errors

This performs unnecessary cryptography and Datascript work and risks observable
side effects before the result is discarded. A duplicate authoritative batch must
not inspect transaction bodies at all.

## Acceptance criteria

- A non-empty normalized transaction encoded as a top-level Transit list decodes
  through the authoritative pull path.
- Empty top-level Transit arrays and lists remain invalid.
- Operation entries that are not Transit arrays remain invalid.
- A duplicate `pull/ok` containing an invalid authoritative transaction body
  succeeds as `Pull_duplicate` without requesting decryption or applying remote
  transactions.
- A duplicate pull containing a transaction cursor newer than the applied cursor
  remains a continuity error.
- Duplicate pull handling continues to clean acknowledged outbox records and apply
  the remaining local projection.

## Risks

- Transit lists are accepted only at the top-level transaction collection. Treating
  operation lists as operation arrays would broaden the wire contract and is out of
  scope.
- Short-circuiting duplicate authoritative wires relies on the durable checkpoint
  and existing cursor-continuity validation as the authority for already-applied
  remote state.

## Consequences

- Deployed historical list collections replay through the same normalized
  operation decoder as array collections.
- Duplicate pulls perform no authoritative transaction parsing, protected-value
  discovery, decryption, or Datascript application.
- Outbox acknowledgement cleanup and local projection remain part of duplicate
  batch processing.

## Verification

- The RED run failed on top-level Transit list replay, malformed duplicate body
  handling, and duplicate outbox projection.
- The GREEN run passes all 46 sync protocol, pure reducer, and effect runner tests.
- `dune runtest` passes the complete repository test suite.

## Questions

- None.
