# Tx Reject Terminal Error Reporting

## Problem

The current `logseq_sync` authoritative WebSocket decoder recognizes
`tx/batch/ok` but not `tx/reject`. A deployed server rejection therefore becomes
the generic parser failure `unsupported authoritative message: tx/reject`.
That message omits the rejection reason, server transaction cursor, partial
success information, failed transaction identity, and any bounded server error
detail. It also describes the client decoder rather than the server decision,
which makes the failure misleading in the application and unusable for support.

The loss of information is observable in the current selected graph. Local
Capture mutations were committed to the durable outbox and transitioned to
`Submitted`; the server then returned `tx/reject`, the client reported only the
unsupported-message error, and the submitted records remained unresolved.
Subsequent queued mutations cannot explain which rejection terminated the sync
path or whether the server reported a stale cursor, invalid transaction, database
failure, or snapshot upload conflict.

The server protocol has multiple rejection shapes. The retired protocol decoder
recognized these reason values:

- `stale`;
- `db transact failed`;
- `empty tx data`;
- `invalid tx`;
- `invalid t-before`; and
- `snapshot upload in progress`.

Depending on the reason, a response may also contain `t`, `success-tx-ids`,
`failed-tx-id`, and `data`. The deployed stale response observed on 2026-08-23
contained only `{"type":"tx/reject","reason":"stale","t":115}`. A useful
error must preserve the distinction between an absent field and a present empty
value without exposing transaction bodies, block content, credentials, or
unbounded server strings.

Existing architecture decisions route stale rejection into automatic
authoritative pull, semantic rebase, and retry. The selected direction is
different: receipt of any valid `tx/reject` terminates the entire selected-graph
sync session. The client closes the WebSocket and stops rather than automatically
pulling, rebasing, retrying, reconnecting, consuming later frames, or submitting
later queued transactions.

## Proposal

Decode `tx/reject` as a first-class authoritative server result and convert it
into one terminal, generation-scoped rejection transition. Do not treat it as a
protocol-decode failure and do not reuse the normal reconnect or uncertain-send
recovery path.

### Decode the complete rejection envelope

Restore a strict typed decoder for the known rejection reasons and their
reason-dependent fields. Reject malformed UUIDs, negative cursors, wrong field
types, inconsistent partial-success shapes, unknown reason values, and oversized
text. The decoder should distinguish:

- the stable rejection category and exact known reason;
- optional server transaction cursor `t`;
- bounded successful transaction IDs;
- optional failed transaction ID;
- presence of optional server `data`; and
- a bounded, sanitized diagnostic rendering of `data` if it is approved for
  display.

Unknown or malformed messages remain protocol errors. A syntactically and
semantically valid `tx/reject` becomes a transaction rejection, never
`unsupported authoritative message`.

### Terminate subsequent sync processing

After accepting a current-generation rejection, durably record the rejection,
fence the entire selected-graph sync session, and close its WebSocket before
publishing the terminal state. No later action may send another transaction,
perform an automatic pull/rebase/retry/reconnect, or consume another WebSocket
frame for that graph session. Duplicate or late callbacks from the fenced
generation must be ignored.

Keep the local mirror readable. Do not delete the mirror, reset the graph, advance
the authoritative checkpoint, or infer that any submitted transaction succeeded
unless the response explicitly and validly identifies it. A submitted record named
in `success-tx-ids` becomes `Accepted` at the reported server cursor when the
response supplies the cursor. Every remaining submitted record becomes durable
`Rejected`, with the named failed transaction carrying the detailed rejection and
any unresolved submitted record carrying the same terminal batch context. Queued
records remain durable but cannot be pumped while the graph is terminal.

The terminal state survives process restart. Restart must reopen the mirror only
for local reads, keep synchronization and Capture disabled, and show that the user
must Reset graph to continue. Reset graph is the only recovery action in scope: it
deletes the terminal mirror and rejected/queued outbox through the existing
confirmed local-cache reset boundary, then performs a fresh authoritative
bootstrap. The confirmation must warn that unsynchronized local changes will be
discarded.

This terminal policy intentionally supersedes the automatic stale-rejection
recovery described by
`2026-08-21-login-sync-port.md`,
`2026-08-23-apple-platform-background-foreground-network-revalidation.md`, and
`2026-08-26-websocket-only-sync-pull-and-transaction-transport.md`. No
compatibility branch should retain automatic retry for `stale` or another
rejection reason.

### Report detailed, display-safe error information

Publish one coherent error assembled by the serialized sync owner at the moment
it fences processing. The minimum report should identify:

- error category: `Transaction rejected`;
- rejection reason using a stable descriptive name;
- server transaction cursor, or `Not provided`;
- local applied server transaction cursor;
- submitted transaction count;
- successful transaction IDs reported by the server, as a count only;
- failed transaction ID, or `Not provided`;
- bounded and sanitized server detail, or `Not provided`/`Redacted`; and
- the terminal scope or generation needed to correlate late callbacks without
  exposing the authenticated user ID or token.

Display the complete `failed-tx-id` because it identifies the rejected local
intent. Do not display individual `success-tx-ids`; report only their count. Accept
server `data` only as valid bounded UTF-8 without NUL bytes, limit the decoded
value to 4,096 bytes, and limit the rendered diagnostic to 1,024 Unicode scalar
values. Normalize line breaks, escape control characters, and replace credentials,
authorization values, signed URL query strings, E2EE material, and transaction or
block payload fragments with `Redacted`. If the value cannot be proven
display-safe, report only `Server detail present: Redacted`.

The primary application error should be concise enough to remain readable, while
Sync diagnostics should expose the complete structured, display-safe fields. If
the diagnostics projection is still unavailable, `snapshot.last_error` must at
least report the rejection reason and cursor rather than the current generic
decoder error. The report must never contain transaction payloads, encoded datoms,
block text, E2EE material, credentials, authorization headers, signed URLs, raw
exceptions, or an unbounded server value.

Do not add persistent logs or analytics. The durable outbox may persist the
bounded terminal reason and failed transaction ID required for restart
truthfulness. Generation, successful-ID count, and sanitized server-detail
diagnostics remain process-local. The durable graph terminal marker must be stored
atomically with the outbox transition so restart cannot resume the graph between
those writes.

### Test the terminal boundary and error projection

Add public-boundary tests for every valid rejection reason and representative
optional-field shape. Tests should prove that a current rejection:

- produces a terminal error with the exact safe fields;
- does not advance the checkpoint;
- does not emit pull, rebase, retry, reconnect, or later submission effects;
- ignores later frames and callbacks from the fenced generation;
- preserves a truthful durable outbox across restart;
- keeps local reads available; and
- disables Capture and every other graph mutation until Reset graph succeeds; and
- omits transaction contents and secret material from state, diagnostics, rendered
  semantics, and test output.

Malformed, unknown, stale-generation, and wrong-graph rejection frames should be
covered separately so a malformed frame cannot impersonate the typed terminal
rejection transition.

## Decision

Adopt the proposal with a graph-wide terminal boundary. Any valid current
`tx/reject`, including `stale`, terminates the entire selected-graph sync session.
The serialized owner atomically persists rejected outbox state and the graph
terminal marker, fences the session, closes the WebSocket, publishes detailed
display-safe error information, and disables Capture and all graph mutations.

The terminal state survives restart. The application keeps the mirror readable
and requires the user to run the confirmed Reset graph action before sync or
writes can resume. Reset discards the terminal mirror and every unsynchronized
outbox record before a fresh authoritative bootstrap.

The error surface displays the complete `failed-tx-id`, but only the count of
`success-tx-ids`. It may display server `data` only after the selected bounds and
sanitization rules; otherwise it reports that server detail was redacted.

## Alternatives considered

### Keep treating `tx/reject` as an unsupported message

This stops the current frame indirectly, but loses all useful server information
and reports the wrong failure category. It also leaves termination and durable
outbox behavior accidental rather than specified.

### Automatically recover `stale` and terminate only permanent reasons

This matches earlier decisions by pulling authoritative state, replanning the
intent, and retrying with the stable mutation ID. It is not selected for this
exploration because the required policy is that receipt of `tx/reject` terminates
subsequent processing, including the `stale` form.

### Report the raw rejection JSON

Raw JSON preserves maximum debugging information, but can include unbounded
server `data`, transaction identifiers without context, or future fields that have
not passed the privacy boundary. Typed decoding plus explicit safe projection
provides useful detail without turning the server payload into a logging API.

### Drop the rejected outbox records

Removing pending records would make the queue appear healthy while silently
discarding unsynchronized local intent. A terminal state must preserve truthful
local status until the product defines an explicit user recovery action.

### Requeue the rejected records without submitting them

Changing `Submitted` back to `Queued` suggests that normal pumping may resume and
makes restart behavior ambiguous. A distinct blocked or rejected terminal state
communicates that automatic processing has stopped.

## Acceptance criteria

- Every currently supported server `tx/reject` reason and valid field shape decodes
  to a typed rejection; malformed and unknown shapes fail closed.
- A valid rejection never reports `unsupported authoritative message: tx/reject`.
- Receipt of a current-generation rejection fences the selected terminal boundary
  and closes the WebSocket before publishing state. It emits no automatic pull,
  rebase, retry, reconnect, later frame application, or later transaction
  submission.
- Late and duplicate frames or completions from the fenced generation cannot
  mutate the checkpoint, outbox, mirror, or public error.
- The authoritative checkpoint does not advance solely because of a rejection.
- The mirror remains locally readable, and the durable outbox truthfully records
  accepted, rejected, and unresolved local intent across restart.
- Restart preserves the graph-wide terminal state, disables every mutation,
  and presents Reset graph as the only recovery action.
- Reset graph uses a confirmation that warns unsynchronized local changes will be
  discarded, deletes the terminal mirror and outbox, and starts a fresh bootstrap.
- The application reports at least the named reason and available server cursor;
  Sync diagnostics reports the complete failed transaction ID, successful-ID
  count, approved sanitized server detail, and explicit absent or redacted values.
- Error state and diagnostics contain no transaction payload, datoms, block text,
  token, credential, E2EE value, signed URL, raw exception, or unbounded server
  data.
- Tests cover all rejection reasons, partial-success metadata, absent optional
  fields, malformed envelopes, stale scopes, duplicate callbacks, queued work
  behind a rejection, local read availability, mutation disablement, reset
  confirmation, destructive reset, and restart truthfulness.
- Repository decision documents that prescribe automatic `tx/reject` recovery are
  explicitly superseded for this path if the exploration is proposed.
- Focused sync and worker tests, the application diagnostics tests, the complete
  repository test suite, `git diff --check`, and `spec-dev-tool check --all` pass.

## Risks

- Treating `stale` as terminal gives up automatic convergence after ordinary
  multi-client cursor races. Local edits can remain unsynchronized until an
  explicit recovery product flow is defined.
- Persisting the graph terminal marker changes the sync storage contract. Its
  atomicity with rejected outbox state must be proven; otherwise restart could
  accidentally resume processing.
- Partial-success responses can report that some submitted IDs succeeded before
  another failed. Stopping immediately without a precise durable representation
  can either resend accepted work later or misreport unresolved work.
- Server `data` may contain valuable database failure detail but may also contain
  graph content or implementation internals. Displaying it without a strict bound
  and sanitization policy expands the privacy surface.
- The complete failed transaction ID improves correlation but makes screenshots
  more identifying. Successful transaction IDs are therefore shown only as a
  count.
- Reset graph intentionally deletes rejected and queued local changes that were
  never synchronized. The confirmation must make this consequence explicit.
- Closing the WebSocket prevents later context from arriving, but retaining it
  would contradict the selected graph-wide terminal boundary.

## Questions

- None. The user selected a graph-wide terminal state, immediate WebSocket close,
  durable `Rejected` records, restart persistence with mandatory Reset graph,
  complete failed transaction ID display, bounded sanitized server detail, and
  disabled Capture.
