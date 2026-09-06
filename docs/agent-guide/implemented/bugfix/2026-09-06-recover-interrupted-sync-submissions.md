# Recover Interrupted Sync Submissions

## Problem

M02 leaves durable Submitted batches without a live submission owner after a
socket disconnect, backgrounding, or process restart. A pulled deletion then
returns Await_submission_outcome and Core fails with
`authoritative defer owner mismatch`. New queued work can overtake unresolved
work, or remain behind an owner waiting indefinitely for a missing response.

Investigation also identified three related defects:

- Database Retry_group rebuilt the wire envelope from the current checkpoint,
  changing the original conditional t_before after an authoritative update.
- Batch IDs used only the Sync revision persisted with active outbox rows. Once
  the outbox emptied, reopening could reset that revision and reuse an ID still
  present in the terminal receipt index.
- Worker reported outbox transition errors only as Diagnostic outputs. Core had
  no failure completion, leaving its pending transition permanently Submitting.

The real test mirror demonstrated the identity collision: Submitted batch
`submission-batch:v1:2` had t_before=498, while an older accepted receipt with that
exact ID covered cursor 480. Retrying reached the server, but the local terminal
receipt lookup rejected the resulting outbox transition.

## Proposal

Recover interrupted submissions using the existing public Retry_group transition;
freeze their original conditional baseline, ordered mutation identities, protected
payload, and batch identity. Release deferred authoritative work only after its
matching terminal response is durably applied. Complete failure ownership and
replace the obsolete revision-only batch allocator.

## Decision

Implemented with the user's authorization to continue sync repairs and make
necessary spec changes on 2026-09-06.

- Core prioritizes orphaned Submitted batches over Queued work. Accepted and
  rejected authoritative barriers prevent new submissions and a premature Current
  phase. Graph-scoped inspection and outbox completions survive socket changes.
- Retry alone does not resume a deferred deletion. Matching durable Accept_group
  or Reject_group completion resumes the same authoritative input or requests
  authoritative catch-up before planning more writes.
- Each live submission has a 30-second response timer. Expiry closes its uncertain
  connection before opening another, fencing untagged late acknowledgements.
- Retry_group preserves original t_before, batch ID, protected transaction bytes,
  member order, and observed origin evidence. Only its attempt count advances.
- New batch IDs use the first member's durable mutation UUID and next attempt
  number. This also applies to independent suffix batches after partial rejection.
  Existing retries retain their frozen ID. No compatibility allocator or migration
  is added.
- `logseq_sync/spec/pure_reducer/core.mli` adds outbox_transition_failure carrying
  the original request and message, plus Outbox_transition_failed. Core matches
  scope, transition, and expected Sync token before consuming a failure, clears
  the pending operation, closes and fences the connection, and reports Failed.
  Late successes, duplicate failures, and old connection responses are inert.
- Worker forwards actual delegated outbox failures through that event. No other
  spec or dune file was changed by this repair; no bonsai_flutter OCaml was edited.

## Alternatives considered

### Infer acceptance from a pulled deletion

Rejected: authoritative presence or absence alone does not replace the existing
terminal transport outcome and conditional non-execution barriers.

### Clear Submitted work or reassign its frozen identity automatically

Rejected: this loses evidence or risks replaying a mutation with a different
conditional baseline. Recover valid batches through their existing frozen wire.

### Use lifecycle or authoritative failure events for outbox errors

Rejected: this misidentifies the failed operation and cannot correlate its original
request. The user approved the explicit outbox failure spec instead.

### Repair the already-colliding test receipt

Not performed. The user designated the graph as disposable test data and chose
redownload instead. Its old directory and a SQLite backup were retained intact.
No receipt was edited and no software migration path was introduced.

## Acceptance criteria

- Public Core tests cover fresh restore, disconnect/reconnect, acceptance and Stale
  rejection, interrupted retry completion, late old responses, queued work,
  authoritative barriers, missing responses, and correlated outbox failures.
- A public Database case advances the checkpoint between Submit_group and
  Retry_group and verifies the complete frozen batch remains unchanged.
- A public Database reopen case incorporates a batch, empties the outbox, reopens,
  submits a new mutation, and verifies distinct IDs and a harmless duplicate old
  acknowledgement.
- Relevant suites, complete Dune checks, formatting, and decision validation pass.
- The rebuilt macOS app reports actual outbox failure truthfully. Under the user's
  revised test-data decision, redownload the graph, synchronize a new marker,
  restart, synchronize a second marker, and verify Current with an empty outbox.

## Validation

The original recovery group went from one passing live-owner control and eight
failing cases to nine passing cases. Two additional failure cases first reproduced
Submitting after a failed outbox completion, then passed: 11 recovery cases total.
The overlay frozen-baseline and reopened-identity cases also failed on the specific
incorrect behavior before implementation and passed afterwards.

The owner-loss and failure-policy regressions use only public pure Core events,
completions, state, and effects. Batch allocation and wire reconstruction execute
inside the mutable Database; Core only receives their opaque results. Their narrow
regressions therefore extend the existing public Database suite. No duplicate
runner, widget, integration, or E2E regression suite was added.

- `dune runtest`: passed, including 129 Sync cases and 49 overlay sync cases.
- `dune build @all`: passed.
- `python3 tool/test_macos_regressions.py`: passed.
- macOS Debug build through the installed bonsai-flutter tool: passed.
- Formatting of all 231 application, package, and test OCaml files: passed.
  The three pre-existing standalone probes under docs/test-reports/reproductions
  are not formatted and were preserved as historical evidence.
- `git diff --check` and spec-dev-tool validation: passed.

The first full test run encountered two existing local transport fixture races:
int_of_string read an empty ready-port file before the fixture completed writing.
The complete rerun passed; no transport implementation or fixture was changed.
The source-boundary allowlist now includes the two mechanical menu files added by
the earlier M05 fix, which had previously missed that final check.

Native observations:

1. The colliding original mirror correctly reported Failed / Ready / Open with
   all four outbox records retained. A temporary payload-free event trace confirmed
   outbox failure, connection close, and preservation of the error afterwards.
2. After the user-authorized redownload and user-entered encryption password,
   the fresh mirror opened at cursor 506 with an empty outbox.
3. `QA-SYNC-20260906 before-restart` received an accepted receipt at cursor 507;
   the outbox emptied.
4. After application restart, `QA-SYNC-20260906 after-restart` received an accepted
   receipt at cursor 508 with a different batch ID. Final inspection showed cursor
   509 and Diagnostics Current / Ready / Open, with zero outbox records/bytes.

See [the validation report](../../../test-reports/2026-09-06-sync-recovery-validation.md)
for the exact evidence and retained backup locations. Temporary instrumentation
was restored byte-for-byte before the final clean native build and write tests.

## Consequences

Interrupted batches retain their original transport evidence and resume before
new queued writes. Failed outbox transitions now expose an explicit terminal
failure instead of an endless progress phase. New submissions cannot collide with
terminal receipts solely because an empty outbox was reopened. The public Core
event boundary changes, and its owning Worker is updated together with it.

## Risks

- A disconnected network still cannot provide a terminal outcome; durable work is
  preserved while response timeouts fence uncertain connections.
- Repeated mutation IDs alone do not provide server idempotence: original
  conditional t_before is essential.

The separate Reset local copy UI lifecycle defect remains in its existing exploring
decision. It tries to delete an open mirror and independently removes its cached
key. During validation it failed busy. The app was then closed, open handles were
checked, and the entire old test mirror directory was moved to backup before
relaunching and selecting Continue online. This was an authorized test-data reset,
not a fix to that UI lifecycle. The original colliding queue was not repaired or
claimed as recovered; the user explicitly selected fresh download instead.

## Questions

None. Required spec and test-data decisions were explicitly supplied by the user.
