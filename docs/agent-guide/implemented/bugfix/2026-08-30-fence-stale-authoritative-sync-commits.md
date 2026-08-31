# Fence Stale Authoritative Sync Commits

## Problem

Authoritative synchronization is split into inspection, optional asynchronous
decryption, planning, and worker-owned persistence. The current pipeline checks
scope before asynchronous work begins but does not prove that the inspected
Engine state is still current when the result commits.

The sequence is:

1. the managed coordinator reads the Engine checkpoint, authoritative database,
   and durable outbox;
2. Core verifies graph, connection, presentation, and lifecycle generations;
3. an encrypted batch retains those values in an `authoritative_plan` while
   decryption runs asynchronously;
4. decryption completion checks only that its effect ticket remains present;
5. `finish_authoritative_batch` produces a commit request containing graph scope
   and replacement state, but no expected Engine state and none of the original
   connection, presentation, or lifecycle generations; and
6. the worker checks only graph scope before `Engine.apply_authoritative`
   unconditionally persists the supplied checkpoint and outbox.

A minimal data-loss sequence is:

1. graph G is inspected at checkpoint `t0` with durable outbox A;
2. an encrypted pull begins decryption and retains A;
3. local mutation B commits successfully, durably writing A+B and updating the
   optimistic projection;
4. the old decryption completes; and
5. the stale authoritative request writes its captured A, removing B even though
   the mutation caller already observed success.

An older authoritative plan can similarly roll back a checkpoint, checksum, or
projection installed by a newer authoritative commit. Storage atomicity does
not prevent the defect because it atomically commits a stale set of inputs.

The encrypted path makes the race easy to reproduce, but correctness must not
depend on the plaintext inspection-to-apply interval remaining short. The
existing `Engine.commit_outbox_transition` already uses an expected-outbox
compare-and-set. Authoritative application needs an equivalent precondition for
the complete Engine sync state.

Relevant implementation boundaries are:

- `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml`:
  `Inspect_authoritative_batch` and `Apply_authoritative_batch`;
- `logseq_sync/lib/pure_reducer/core.ml`: pending authoritative plans and crypto
  completion;
- `logseq_sync/spec/pure_reducer/core.mli`:
  `authoritative_commit_request`; and
- `logseq_db_worker/lib/engine.ml`: `commit_managed_mutation`,
  `commit_outbox_transition`, and `apply_authoritative`.

## Proposal

Introduce a worker-issued authoritative precondition and require every
authoritative commit to compare-and-swap against it.

The precondition should identify both the exact Engine instance that produced
the inspection and a monotonic sync revision for that instance. The revision
must change after every successful operation that affects authoritative
planning or its result, including:

- local mutation publication and durable outbox insertion;
- durable outbox state transitions;
- authoritative transaction, checkpoint, and outbox commits; and
- Engine replacement or reattachment through a new instance identity.

Inspection should return this opaque precondition with the checkpoint, database,
and outbox. Core must preserve it unchanged through `authoritative_plan` and
`authoritative_commit_request`; Core must not construct or interpret worker
revisions.

Retain the original authoritative batch scope through the finished commit
request. When asynchronous crypto completes, Core must revalidate graph,
connection, presentation, and lifecycle generations before delegating an apply.
An obsolete completion must be discarded before it reaches the worker.

Engine remains the final authority. The replacement authoritative apply must,
inside the serialized worker boundary:

1. verify Engine-instance identity and expected sync revision before staging;
2. perform no durable or in-memory mutation when the precondition differs;
3. atomically commit authoritative transactions, checkpoint, and outbox when it
   matches;
4. publish the rebuilt projected database only after the complete operation
   succeeds; and
5. advance the revision only after success.

If any Engine access can occur outside the coordinator lock, revalidate the
precondition immediately before the storage commit as well. A rejected
precondition must leave no staged state, publish no invalidation, and never
replace current projection or outbox values.

Represent precondition mismatch as a typed authoritative conflict rather than
`Authoritative_batch_failed`. Expected contention with a local mutation is not a
catalog failure and must not move sync to `Failed`.

For a conflict whose original scope is still current, retain one bounded,
coalesced retry demand and inspect current Engine state again before replanning.
A conflict from an obsolete account, graph, connection, presentation, or
lifecycle scope must be dropped. Replace the unconditional apply contract; do
not add a fallback that retries without the precondition.

Core should own at most one active authoritative plan per graph and coalesce
later authoritative demand while crypto or apply is in progress. Repeated CAS
conflicts must yield to the local mutation lane and retain one retry token rather
than recursively starting unbounded work.

## Decision

Adopt the opaque `(Engine instance, monotonic revision)` authoritative
precondition and the single active authoritative-plan owner described above.

When Engine CAS rejects a completion but its account, graph, connection,
presentation, and lifecycle scopes are still current, retain the original typed
server message and inspect it again against a fresh Engine snapshot. Do not rely
on a fresh pull as the only recovery action: a `Tx_batch_ok` can be a one-time
response and discarding it would lose the acknowledgement owned by the active
single-flight submission.

After the retained message commits successfully, coalesce one pull demand so the
client confirms the resulting authoritative cursor. Repeated conflicts retain at
most one retry owner and one pull demand. If any original scope is obsolete, drop
the message and its retry instead of applying it to the replacement session.

## Alternatives considered

### Recheck only Core generations after decryption

This is necessary but insufficient. A local mutation changes the worker's
durable outbox and projection without changing any Core generation, so the plan
can remain generation-current while its Engine snapshot is obsolete.

### Compare only checkpoint and serialized outbox bytes

This catches the demonstrated races and resembles the existing outbox CAS, but
it exposes persistence representation through the reducer and permits an ABA
state if values return to earlier bytes. An opaque instance/revision token is a
single complete precondition.

### Hold the coordinator lock while decrypting

This would serialize away the race at the cost of blocking all local-first reads
and writes behind platform crypto. It would also turn slow or canceled crypto
into whole-service latency.

### Re-read Engine state after decryption

Re-reading narrows the race but another commit can still occur between the read
and persistence. The final storage owner must enforce CAS.

### Discard conflicts and wait for another server message

The delivered pull or acknowledgement may not be repeated. Dropping its demand
can leave the client permanently behind, so current-scope conflicts need an
owned retry.

## Acceptance criteria

- A test can pause encrypted authoritative decryption, commit a local mutation,
  release decryption, and prove that the stale request performs no storage write.
- The concurrent local mutation remains durable, visible in the projection, and
  retains the success already returned to its caller.
- A paused older authoritative plan cannot roll back a newer checkpoint,
  checksum, authoritative database, outbox, or projection.
- Plaintext and encrypted paths use the same Engine CAS contract.
- Account, graph, connection, presentation, or lifecycle replacement prevents
  an old crypto completion from reaching Engine apply.
- Every local mutation commit, outbox transition, and authoritative commit
  invalidates older authoritative preconditions.
- Engine replacement invalidates all preconditions from the prior instance even
  when graph ID and numeric revision happen to match.
- A conflict performs no durable or in-memory mutation, emits no graph
  invalidation, and does not classify itself as a catalog failure.
- A current-scope conflict produces one bounded, coalesced retry that starts from
  a fresh Engine inspection.
- Repeated contention cannot create an unbounded retry loop or duplicate apply.
- Successful commits retain the atomic transaction/checkpoint/outbox guarantee.
- Focused Core, Engine, coordinator, restart, and end-to-end race tests pass.
- The obsolete unconditional apply API and implementation are removed without a
  compatibility path.

## Risks

- Missing one Engine operation that must advance the revision silently recreates
  the stale-write vulnerability.
- Continuous local mutation can repeatedly invalidate authoritative work and
  starve pull progress unless retry ownership is explicit and bounded.
- Treating expected contention as a fatal error would make ordinary local-first
  activity user-visible as sync failure.
- A revision without Engine-instance identity can collide after detach/reopen.
- Projection reconstruction can fail after planning. The complete projection
  must be validated before durable commit rather than pretending a committed
  checkpoint can be rolled back in memory.
- Exposing raw outbox content as a precondition would couple Core to worker
  persistence and risk logging mutation contents.

## Consequences

- Every Engine instance exposes an opaque precondition combining instance
  identity and a monotonic sync revision.
- Local commits, outbox transitions, and authoritative commits invalidate all
  previously inspected authoritative plans.
- A failed precondition produces a typed conflict before any durable or
  in-memory state change and does not publish graph invalidation.
- Core owns one active authoritative batch and one coalesced queued batch,
  bounding retry work under contention.
- Projection reconstruction must complete successfully before the atomic
  authoritative storage commit can proceed.

## Questions

- None. The user selected retention and re-inspection of the original typed
  server message, followed by a coalesced pull after successful application.

## Implementation

Engine assigns each opened instance a unique identity and advances its revision
after every sync-relevant commit. `authoritative_precondition` returns an opaque
token, and `apply_authoritative` checks it before staging and immediately before
the storage commit. The API returns `Authoritative_conflict` separately from
apply failures.

Core correlates authoritative work with account, graph, connection,
presentation, and lifecycle generations. It serializes authoritative batches,
coalesces one retained typed retry, and handles an Engine conflict without
classifying it as catalog failure.

## Verification evidence

- Engine tests pass for a local commit invalidating an older authoritative
  precondition without overwriting the local projection.
- Reducer and worker suites pass for scoped authoritative ownership and conflict
  handling.
- `dune build @all`, `dune runtest`, and `git diff --check` pass.
