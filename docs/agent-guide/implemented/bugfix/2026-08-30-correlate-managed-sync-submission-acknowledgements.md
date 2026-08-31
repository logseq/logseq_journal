# Correlate Managed Sync Submission Acknowledgements

## Problem

The managed sync reducer does not own one identifiable transaction batch at a
time. `plan_submission` selects every queued record up to the count limit and
persists those records as `Submitted`, but it does not check whether another
record is already `Submitted`, whether an acknowledgement is pending, or
whether the opening pull has established the current authoritative cursor.

`Websocket_opened` sets `websocket_live = true` before the opening pull
completes. `Local_batch_committed` can therefore call `plan_submission` while
the reducer is `Pulling`, and successive local commits can create several
`tx/batch` messages with the same `t-before`.

The server's `tx/batch/ok` message contains only the resulting cursor and an
optional checksum. It does not echo a client batch identifier or the submitted
transaction IDs. The reducer nevertheless handles any acknowledgement by
changing every durable `Submitted` record to `Accepted t`, regardless of which
records were included in the acknowledged message.

A minimal loss sequence is:

1. the socket opens at local cursor 0 and the opening pull remains in flight;
2. local mutation A is persisted as `Submitted` and sent with `t-before = 0`;
3. local mutation B is also persisted as `Submitted` and sent with
   `t-before = 0`;
4. the server accepts A and returns `tx/batch/ok` at cursor 1;
5. the reducer marks both A and B as `Accepted 1`; and
6. a pull through cursor 1 contains A and removes both records, even if B was
   rejected, never delivered, or not represented by that cursor.

This violates the durable-outbox invariant: a server acknowledgement may only
advance the exact records owned by the acknowledged submission. The current
state machine can delete a local intent that the server never accepted.

Relevant implementation boundaries are:

- `logseq_sync/lib/pure_reducer/core.ml`: `begin_authoritative_batch`,
  `plan_submission`, `local_batch_committed`, and `websocket_opened`;
- `logseq_sync/spec/pure_reducer/sync_protocol.mli`: `Client.Tx_batch` and
  `Server.Tx_batch_ok`; and
- `logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml`:
  `Commit_outbox_transition` durability before send.

## Proposal

Give each managed graph one explicit submission lane and never infer batch
ownership from all records that happen to have the `Submitted` state.

With the current remote protocol, enforce at most one in-flight batch per graph:

- do not open the submission lane until the opening pull has been applied and
  the reducer is `Current`;
- select a bounded ordered set of queued mutation IDs as the lane owner;
- atomically persist only those records as `Submitted` before sending;
- retain the owned mutation IDs and `t-before` until the acknowledgement and
  its required authoritative pull have completed;
- apply `tx/batch/ok` only to the records owned by that lane;
- ignore duplicate or stale acknowledgements that have no current owner;
- do not send another batch while owned records are `Submitted` or `Accepted`
  and awaiting authoritative confirmation; and
- release the lane only after the authoritative pull has reconciled the exact
  accepted records against its cursor.

The durable outbox remains the recovery source. The reducer may keep an
in-memory owner for the live connection, but persisted `Submitted` records must
never be treated as belonging to an unrelated acknowledgement after reconnect.
Uncertain-submission recovery after process restart is a related but separate
decision; this repair must leave those records durable and unacknowledged rather
than deleting them speculatively.

Submission eligibility must be a first-class predicate. `websocket_live` means
only that a socket exists; it must not mean that the opening pull is complete,
that the cursor is current, or that the submission lane is idle. The reducer
must also prohibit submission in `Connecting`, `Pulling`, `Submitting`,
`Paused`, `Failed`, and `Offline`.

Add deterministic reducer and worker-coordinator tests for two rapid mutations,
duplicate acknowledgements, a local commit during the opening pull, a changed
connection generation, and an acknowledgement followed by a pull that contains
only the owned batch.

## Decision

Adopt the client-only single-flight design under the existing server protocol.
Do not require or introduce a server-echoed batch ID as part of this repair.

Each graph connection owns at most one non-durable live submission descriptor.
The descriptor contains the exact mutation IDs, `t-before`, message, and current
connection, presentation, and lifecycle scope. A new local mutation remains
durably `Queued` while that descriptor is reserving, dispatched, acknowledged,
or awaiting authoritative confirmation.

The opening pull must complete before the descriptor can be created. A
`tx/batch/ok` applies only to its descriptor's records, and the next descriptor
cannot start until a pull reaches the acknowledged cursor and reconciles those
records.

The live descriptor is intentionally not persisted. After process or connection
loss, recovered `Submitted` records are uncertain attempts. The replacement
connection must complete its opening pull and then use the selected complete
`Submitted`/`Accepted` semantic recovery policy. It must never assign those
records to an unrelated acknowledgement or resend their old `encoded_tx`.

## Alternatives considered

### Add a client batch identifier to the remote protocol

An echoed batch identifier would permit multiple in-flight batches and direct
correlation. The current server response does not provide one. Depending on a
new wire contract expands the repair into a coordinated server/client rollout
and does not remove the need for opening-pull and lifecycle fences.

### Correlate by returned cursor or checksum

The returned cursor and checksum describe authoritative server state, not the
membership of a client submission. Several batches can share one `t-before`,
and the response contains no evidence that every local `Submitted` record was
accepted. Cursor inference therefore cannot safely identify a batch.

### Treat every durable `Submitted` record as one implicit batch

This is the current behavior. It loses ownership as soon as a second transition
to `Submitted` commits before the first acknowledgement. Restricting the lane is
required even if the outbox state names remain unchanged.

### Serialize only on the public sync phase

Checking `sync_phase = Current` prevents opening-pull submission but does not
identify which records an acknowledgement owns. Phase is presentation state,
not durable batch correlation, so an explicit owner is still required.

## Acceptance criteria

- A managed graph has at most one transaction batch awaiting acknowledgement or
  authoritative confirmation.
- No `tx/batch` is emitted before the opening pull has been applied.
- Two rapid local commits cannot produce two batches with the same stale
  `t-before`.
- `tx/batch/ok` changes only the outbox records owned by the current submission.
- An acknowledgement with no current owner cannot change any outbox record.
- A duplicate acknowledgement cannot accept a later queued or submitted
  mutation.
- A pull removes only records proven accepted at or before its authoritative
  cursor.
- Submission remains disabled while sync is offline, connecting, pulling,
  submitting, paused, or failed.
- The durable transition still occurs before the corresponding WebSocket send.
- Reducer tests cover A/B interleavings, opening-pull writes, duplicate acks,
  stale connection generations, and ack/pull reconciliation.
- Worker tests prove that rejected compare-and-set transitions cannot send a
  batch or mutate the reducer's owner.
- Existing single-batch happy-path behavior remains supported without a
  compatibility state machine.

## Risks

- Single-flight submission reduces maximum write throughput relative to a
  correlated multi-flight protocol.
- Waiting for the authoritative pull before releasing the lane adds one network
  round trip between batches.
- An in-memory owner alone is insufficient for crash recovery; the repair must
  not accidentally reinterpret recovered `Submitted` records as a new live
  batch.
- Submission ownership, semantic replan, and uncertain-submission recovery
  interact. Tests must keep their responsibilities explicit instead of solving
  one by weakening another.

## Consequences

- Each managed graph has one in-memory submission owner from durable reservation
  through acknowledgement and authoritative confirmation.
- An acknowledgement can update only the mutation IDs captured by that owner;
  unsolicited and duplicate acknowledgements are inert.
- New submissions wait until the opening pull is applied and the prior owner is
  released by an authoritative cursor.
- Durable `Submitted` and `Accepted` records recovered without a live owner are
  treated as uncertain work and are not silently adopted by a later batch.
- Throughput is intentionally single-flight until the remote protocol provides
  an explicit correlation identifier.

## Questions

- None. The user selected client-only single-flight, a non-durable live
  submission owner, and opening-pull recovery for durable uncertain records.

## Implementation

Core now maintains a scoped submission-owner state machine covering reservation,
dispatch, acknowledgement application, and authoritative-pull confirmation.
The owner is installed before the durable outbox compare-and-set transition,
and the WebSocket send occurs only after that transition succeeds.

`tx/batch/ok` records the accepted cursor only for the current owner's mutation
IDs. Pull reconciliation releases the owner only after reaching that cursor,
while durable uncertain states block unrelated submission.

## Verification evidence

- Reducer tests pass for reservation-before-send, acknowledgement without an
  owner, duplicate acknowledgement isolation, and durable outbox gating.
- The focused sync suite reports 52 passing tests.
- `dune build @all`, `dune runtest`, and source-boundary tests pass.
