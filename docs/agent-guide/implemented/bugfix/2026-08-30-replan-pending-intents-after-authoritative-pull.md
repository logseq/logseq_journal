# Replan Pending Intents After Authoritative Pull

## Problem

The durable managed outbox stores both a semantic `mutation_payload` and a
transport-specific `encoded_tx`. The semantic payload is the complete mutation
JSON needed to plan the user's intent again, while the encoded transaction was
derived from one particular projected database.

The current authoritative path never reads `mutation_payload` after decoding an
outbox record. When a pull advances the authoritative database, the reducer
decodes every pending record's existing `encoded_tx` against the new database
and uses the same bytes for the next submission. This treats an old transaction
as if it were the durable intent.

That distinction matters for cardinality-one attributes, entity creation,
deletion, page identity, and other operations whose planner output depends on
the database before the mutation. A transaction planned against an old mirror
can contain retracts or assertions that are no longer valid after remote
changes. Sending those bytes at the new server cursor can overwrite remote
fields or recreate an operation that authoritative state already satisfies.

The repository already records a production instance of this failure. A
deferred create-page mutation was planned before an opening pull. The pull found
the existing page and the semantic rebase blocked the duplicate intent, but the
old transport payload was still submitted and retracted current remote page
attributes. Earlier architecture decisions therefore require semantic
replanning after authoritative catch-up, not raw transaction comparison or
replay.

The current split reducer/worker implementation has regressed that invariant:

- `mutation_payload` is encoded and decoded but has no production consumer;
- `begin_authoritative_batch` retains records by state and copies their old
  `encoded_tx` values into the projection;
- `finish_authoritative_batch` decodes those old wires against
  `database_after`; and
- `plan_submission` later emits the unchanged wires.

The result can preserve a readable optimistic projection while silently
changing the meaning of a later remote submission. Durable intent ownership and
transport encoding ownership are currently conflated.

## Proposal

Restore `mutation_payload` as the only semantic source for pending-intent
recovery after any authoritative database change.

The worker-owned managed coordinator should perform an ordered replan before it
commits a new authoritative checkpoint:

1. decode each retryable outbox record's `mutation_payload` through
   `Logseq_db_types.Mutation.of_yojson`;
2. apply the authoritative transactions to a staged authoritative database;
3. visit pending intents in durable order and run the normal worker planner
   against the progressively rebuilt projection;
4. classify each intent as already satisfied, replanned, blocked, or invalid;
5. pass newly planned operations to the sync reducer for current E2EE and
   Transit encoding rather than retaining the previous `encoded_tx`;
6. atomically commit the authoritative database, checkpoint, rebuilt
   projection, and replacement outbox records only if the Engine revision used
   for planning is still current; and
7. submit only the newly encoded transaction associated with the original
   stable mutation ID.

Before planning, decode the payload through
`Logseq_db_types.Mutation.of_yojson`, derive its shared identity again, and
require the decoded mutation ID and fingerprint to match the durable record.
The derived outliner operation must also agree with stored metadata. Any mismatch
is durable corruption and must fail closed; it must never fall back to the old
wire transaction.

Replan is distinct from initial admission. The mutation's original expected
basis is necessarily stale after an authoritative pull, so the recovery API must
preserve semantic payload and identity while deliberately planning against the
new sequential projection.

An already-satisfied replan produces no remote transaction and removes the
pending record only as part of the same authoritative commit. A retryable
non-empty replan retains the original mutation ID, fingerprint, semantic
payload, and durable ordering, but replaces the transport transaction. A
blocked intent must retain its semantic payload and a structured reason; its old
encoded transaction must never remain eligible for submission.

Replanning must be sequential because later local intents can depend on the
optimistic effects of earlier ones. It must use the same planner as a fresh
managed mutation instead of adding a reduced recovery planner. Encryption and
wire encoding remain sync-owned, while Engine state and atomic persistence
remain worker-owned.

`Submitted` and `Accepted` records require explicit reconciliation before
replanning because their transport attempt may already have reached the server.
The fix must not rewrite or resend an uncertain attempt merely because a pull
started. The submission-acknowledgement decision defines attempt ownership; once
authoritative catch-up proves that an intent remains unsatisfied, the semantic
replan can safely create its next attempt.

Remove the obsolete path that derives projection and future submission directly
from a stored pre-pull `encoded_tx`. Do not keep a fallback that submits old
bytes when mutation decoding or replanning fails.

## Decision

Adopt complete semantic recovery for `Queued`, `Submitted`, `Accepted`, and
`Blocked` records rather than repairing only the queued path.

Recovery follows this order:

1. complete the generation-fenced opening or recovery pull before permitting a
   new submission;
2. confirm `Accepted` records only from the authoritative cursor;
3. treat recovered `Submitted` records without a live single-flight owner as
   uncertain attempts;
4. evaluate each uncertain intent against the authoritative state;
5. remove an intent when authoritative state already satisfies it;
6. return an unsatisfied retryable intent to `Queued` and semantically replan it
   in durable order; and
7. never submit the pre-recovery `encoded_tx` from any outbox state.

An `Accepted` record whose acknowledgement cursor has not yet been reached
remains accepted and may be semantically replanned only to rebuild the local
projection; it is not eligible for another submission. A `Blocked` record is
never projected or submitted from stale transaction bytes.

If one intent cannot be decoded, validated, planned, encrypted, encoded, or
projected, retain it as durable `Blocked` and block the complete ordered suffix.
The current system has no proof that later intents are independent, so it must
not continue them against a projection that omits an earlier user action.

Use replan time for planner-generated dates. Do not extend the durable intent
contract with an admission timestamp as part of this repair. The original
mutation ID, semantic payload, fingerprint, and durable order remain stable;
only the database-dependent plan, encoded transaction, and applicable outbox
state may change.

## Alternatives considered

### Continue replaying the stored encoded transaction

This is the current behavior. A transaction is an execution plan for a specific
database, not the user's durable semantic request. Replaying it after
authoritative change is the defect being repaired.

### Compare outgoing and pulled transaction bytes

The server normalizes transactions, can add transaction entities, expands
cardinality-one changes, and may use different Transit cache references. Wire
equality cannot prove that an intent was accepted or remains valid.

### Replan only after a stale rejection

Every authoritative pull can invalidate the assumptions of a queued intent,
including the opening pull before the first submission. Waiting for a server
rejection still permits a stale transaction to be accepted and cause damage.

### Add recovery-specific mutation planners

A second planner would drift from normal mutation semantics and make retries
behave differently from new requests. Recovery should decode the durable
mutation and call the same worker-owned planner.

### Drop every pending record after a remote change

Dropping avoids stale submission but loses offline edits. The semantic payload
exists specifically so the client can preserve and re-evaluate user intent.

## Acceptance criteria

- Production code reads every retryable record's `mutation_payload` during
  authoritative replan.
- No pre-pull `encoded_tx` is reused as the post-pull projection or next remote
  submission.
- Pending intents are replanned in durable order against the authoritative
  database plus earlier replanned intents.
- A no-op replan removes an already-satisfied intent without sending it again.
- A non-empty replan preserves the stable mutation ID and semantic fingerprint
  while replacing the transport encoding.
- A blocked or invalid intent cannot retain an eligible stale transaction.
- `Submitted` and `Accepted` records are reconciled before any new attempt is
  generated.
- Authoritative data, checkpoint, rebuilt projection, and replacement outbox are
  committed atomically against an expected Engine revision.
- A concurrent local mutation causes the stale replan commit to be rejected and
  retried; it is never overwritten.
- Tests cover a remote cardinality-one change, existing journal-page creation,
  remote deletion, an already-satisfied intent, dependent ordered intents,
  blocked replanning, E2EE re-encoding, and an uncertain submitted attempt.
- The documented stale deferred create-page regression cannot submit its old
  transaction bytes.
- The obsolete encoded-transaction replay path is removed without a fallback or
  compatibility layer.

## Risks

- Replanning all pending intents is proportional to outbox length and can add
  latency to large authoritative pulls.
- Sequential intents may become blocked as a group when an earlier dependency
  cannot be replanned; a partial-recovery policy must not expose an internally
  inconsistent projection.
- E2EE re-encoding introduces an asynchronous boundary inside replan and must be
  protected by the authoritative Engine revision decision.
- Mutation JSON is a durable semantic contract. Removing or changing decoders
  without an explicit storage decision can make old intents unplannable.
- Incorrect no-op detection could discard a user intent that the authoritative
  state only partially satisfies.
- Planner-generated timestamps can change when an intent is replanned unless
  their source is made an explicit durable semantic decision.

## Consequences

- Authoritative pull rebuilds pending work from durable semantic mutation
  payloads instead of replaying pre-pull transaction bytes.
- Replanning is ordered: each successful intent updates the staged projection
  used to plan the next intent.
- Already-satisfied intents are removed, successful intents preserve stable
  identity with fresh transport encoding, and the first invalid intent blocks
  itself and the remaining ordered suffix.
- E2EE graphs encrypt newly planned protected values before the authoritative
  compare-and-set commit.
- Authoritative data, checkpoint, replacement outbox, and rebuilt projection are
  installed atomically under the same Engine precondition.

## Questions

- None. The user selected complete state recovery, blocking the ordered suffix
  after the first failed intent, and replan time for planner-generated dates.

## Implementation

The worker decodes and verifies each retryable record's `mutation_payload`,
mutation ID, fingerprint, and outliner operation. It applies remote transactions
to a staged database, invokes the shared Engine mutation planner sequentially,
and replaces transport encodings without changing durable intent identity or
order.

No-op plans are removed. Invalid plans and their suffix are stored as blocked
records with empty safe transport. E2EE replans use the effect runner's protected
value encryption path. Engine validates the completed projection and commits it
atomically with authoritative state, checkpoint, and replacement outbox under
the inspected precondition.

## Verification evidence

- Engine tests pass for ordered semantic replan against stale basis data and
  already-satisfied intent elimination.
- Reducer tests prove duplicate pulls never return stored `encoded_tx` as a
  projection transaction.
- The focused sync, Engine, and Bonsai service suites, `dune build @all`, and
  full `dune runtest` pass.
