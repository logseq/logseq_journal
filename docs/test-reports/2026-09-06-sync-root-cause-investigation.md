# macOS Sync Failures: Reproduction and Root Causes

Follow-up: the [sync recovery validation](2026-09-06-sync-recovery-validation.md)
records the subsequent repairs and successful fresh-mirror write/restart checks.
The observations below describe the original failure before those repairs.

Date: 2026-09-06. All times below use Asia/Shanghai (UTC+08:00).

Scope: investigate M01 and M02 from [the macOS audit](2026-09-06-macos-graph-mutations-and-sync.md). No production fix was implemented. The investigation used the existing working-tree changes on HEAD `7a6fcae`, macOS 26.6.2 arm64, and the Debug macOS app built through `bonsai-flutter`.

## Findings

| Issue | Confirmed defect | Evidence |
| --- | --- | --- |
| M01: incoming changes do not refresh the timeline | The worker removes an acknowledged window, then requires that same window to resolve the next `after` cursor. It returns no changes when the cursor is absent. A repeated acknowledgement can also discard unseen windows. | Earlier live peer-to-macOS observation plus a repeatable probe calling the actual worker helpers. |
| M02: submitted deletion blocks sync and survives restart | Durable `Submitted` records outlive their in-memory submission owner. The owner is cleared on disconnect/restart, but there is no recovery path that reconstructs or resolves it. The pulled deletion then defers for that missing owner and Core fails. | Original queue startup trace, controlled interruption of a real macOS submission, Core reproduction, and an actual overlay defer/accept control. |

**Historical limit:** the original audit did not capture the first deletion's batch response. Its initial missing or unprocessed acknowledgement cannot be reconstructed from the available evidence. This investigation establishes why a submission without a completed acknowledgement stalls, and why restart cannot recover it. The controlled interruption demonstrates a sufficient trigger; it does not prove that the original incident experienced the same interruption.

## M01 — Acknowledged change cursor becomes unusable

### Live reproduction

1. Open the encrypted `ocaml-sync-test` graph in the macOS app and the authenticated Logseq web peer.
2. In macOS, create a marker block and wait until it appears on the peer.
3. On the peer, change the marker title to `QA-20260906-1352 edited-from-web` and add a child named `QA-20260906-1352 child-from-web`.
4. Leave macOS running and inspect its timeline.
5. Independently inspect the local mirror, then restart macOS.

Observed in the audit: the local mirror contained the updated title and child at cursor 498, while the running timeline remained stale. Restarting exposed the updated data. The relevant block UUIDs were `ea6adc54-268f-427b-8ee5-c6c0d3bdbfbf` and `6a9d00a9-8930-46e2-bc77-438cfc51f78d`.

### Exact causal sequence

The producer in `logseq_db_worker/lib/effect_runner/effect_runner.ml:461` retains projection windows in `database_session.windows` and emits `V2_changes_available`.

The consumer in `app/journal_graph_runtime.ml:1584` saves the returned `through` as `change_cursor` and immediately sends `V2_ack_changes`. On the next push, `reconcile_push` at line 1606 uses that saved cursor as `after`.

The worker's `pull_changes` at line 826 resolves `after` by searching **the retained windows**. Its missing-cursor case returns `[]`. Meanwhile, `acknowledge_changes` at line 880 has already removed the acknowledged window and all earlier windows.

```text
retained windows = [w0]
pull(after=None)  -> [w0], through=w0
ack(w0)          -> retained windows = []
new change w1    -> retained windows = [w1], push emitted
pull(after=w0)   -> [], through=w0       # w0 was removed
ack(w0)          -> retained windows = [] # unseen w1 discarded
```

This is a cursor-retention contract error. The graph database can advance normally while the application receives an empty change feed. It explains why restart can display the already-synced contents: the process no longer reuses the stale cursor. It also establishes a path to stale mutation revisions, although separate mutation-conflict fixes were outside this investigation.

### Deterministic reproduction and control

`probe-m01.ml` loads the actual worker implementation with `#mod_use`, creates a disposable database/session, and calls its real `pull_changes` and `acknowledge_changes` helpers. It does not duplicate those algorithms.

Results:

```text
first pull=1; retained-after-ack=0
second pull(after=change-window:v1:0)=0
control pull(None)=1
subsequent push: pull(after=old cursor)=0; retained=2
re-acknowledging stale cursor discarded both unseen windows
```

The `after=None` control proves that the windows exist and can be read. Using the acknowledged cursor is what makes them disappear from the consumer's view.

A correction will need to preserve the validity of acknowledged cursor boundaries and make repeated acknowledgements safe for newer windows. That correction has not been implemented here.

## M02 — A submitted deletion loses its recovery owner

### Original persisted failure

The original mirror was retained intact:

| Record | State | Attempts | Submission base |
| --- | --- | --- | --- |
| Todo deletion, mutation `542e23eb-bbd0-495e-8364-7b7100024e8f` | `submitted`, batch `submission-batch:v1:2` | 1 | 498 |
| Parent/subtree deletion | `queued` | 0 | none |
| Subsequent capture | `queued` | 0 | none |

The peer had already removed the Todo. During the instrumented restart of this original mirror:

```text
14:20:24.806 websocket-opened -> Pulling, cursor=498
14:20:25.033 pull-ok t=499, txs=1
14:20:25.043 Failed, cursor=498
error="authoritative defer owner mismatch"
```

The server returned the missing transaction. The failure occurred while reconciling it locally, after a successful connection and pull.

### Controlled macOS reproduction

To avoid altering the original three-record queue, the test used a disposable SQLite backup with its outbox and receipt tables cleared, a copied catalog, and a temporary application-support-directory override. Existing authentication and the cached graph key were used. This remained connected to the same named test graph, so only uniquely named test records were edited. The original mirror was not cleared or reset.

The copied database initially failed its read-only inspection because of its SQLite journal setup. Switching **only the disposable copy** to DELETE journal mode made the checkpoint readable; the app then attached and reached `Current` at 499. This setup error is not counted as a new product sync defect.

First, control operations completed:

| Operation | Server acknowledgement | Local result |
| --- | --- | --- |
| Create ordinary marker | `batch-ok t=500` | Pull completed; cursor 500 |
| Delete ordinary marker | `batch-ok t=501` | Pull completed; cursor 501 |
| Create Todo marker | `batch-ok` and subsequent pull | Peer displayed the Todo |
| Delete Todo marker | `batch-ok t=504` | Pull completed; cursor 504 |
| Create interruption marker | `batch-ok t=505` | Peer displayed the marker; cursor 505 |

Then:

1. Delete `QA-20260906-1434 interrupted-delete`, block UUID `5f91da9e-0dd8-4b0a-89c9-9a1d0b89daa1`, through the macOS swipe/Delete UI.
2. Observe the disposable outbox becoming `submitted` at 14:37:42.440.
3. Interrupt that isolated app process approximately 105 ms later, at 14:37:42.545, before a batch acknowledgement appears in the client trace. This is deliberate fault injection simulating a process crash during an in-flight submission.
4. Confirm the peer has removed the block. The server processed the deletion.
5. Restart the macOS app against the same disposable mirror.
6. Observe the new connection return `pull-ok t=506` at 14:38:07.243; approximately 4 ms later, Core enters `Failed` with `authoritative defer owner mismatch`. Local cursor remains 505.

The persisted deletion remains `submitted`, batch `submission-batch:v1:27`, attempts 1, base 505, with no observed origin cursor. This recreates the important original failure: remote deletion applied, local submission unresolved, and restart unable to advance the local mirror.

### Root cause through the layers

1. **Submission ownership is volatile.** `logseq_sync/lib/pure_reducer/core.ml:560` defines the owner as an in-memory batch/connection record. Initial state has no owner. `start_websocket` at line 777, `websocket_closed` at line 1996, and the background lifecycle branch at line 2195 clear it. The durable outbox keeps its `Submitted` record.
2. **Submitted records have no restart recovery path.** `plan_submission` at line 1224 selects only dependency-eligible `Queued` descriptors. It does not reconstruct an owner for a durable `Submitted` batch. No path schedules `Retry_group` to resolve this interrupted submission. `Timer_elapsed` at line 2256 is a no-op, so waiting does not supply acknowledgement recovery.
3. **The overlay deliberately waits for a definitive batch outcome.** `logseq_overlay_db/lib/database.ml:6140` identifies unresolved submitted deletions. At line 6240, even a matching own-origin deletion can return `Await_submission_outcome batch_id` instead of committing the incoming batch. This ordering prevents a deletion from being finalized before its transport outcome has been resolved.
4. **Core cannot satisfy that wait after restart.** `authoritative_deferred` at `core.ml:1661` requires a matching `submission_owner`. With `None`, it fails with the exact live error. The cursor and durable outbox remain unchanged.
5. **A late old response is insufficient.** `websocket_message` at line 1548 checks the current connection, and `Tx_batch_ok` at line 1572 also requires an owner on that connection. A late acknowledgement from the old connection is ignored. There is no independent durable reconciliation mechanism to finish the old batch.

This is an ownership/recovery gap between persistent outbox state and the transport's process-scoped state. Reopening a socket alone cannot repair it.

### Consequence for subsequent writes

While the original live owner is waiting, `plan_submission` does not start another batch; this accounts for a growing queued backlog when the acknowledgement never finishes.

After losing that owner, behavior can differ. In the controlled test, a later capture named `QA-20260906-1434 queued-after-interruption` was actually submitted using stale base 505, then received `tx-reject` at 14:38:50.211. Its persisted state became `deleteBarrierRejectedPendingAuthoritative`, through 506, attempts 1. It did not appear on the peer. The phase returned to `Current` while retaining the owner-mismatch error and cursor 505.

Thus “everything remains queued” is not a universal description: later work can also be rejected and stranded behind the unresolved authoritative deletion. The detailed persisted states are in [the sanitized evidence](reproductions/2026-09-06-sync-evidence.json).

### Deterministic controls

`probe-m02.ml` loads the actual Core implementation and uses existing contract-test setup. It proves:

- With a live matching owner, a deferred pull is retained without failure; `Tx_batch_ok` requests `Accept_group`.
- Disconnect clears the owner. Reopen, pull, and the same defer event produce `Failed` with the exact live error.
- An old-connection acknowledgement has no effects.
- A later local-outbox notification cannot release the waiting owner/deferred batch without a transport outcome.

`probe-overlay-delete.ml` runs the existing real-database scenario `submitted_delete_defers_authoritative_batch_until_transport_outcome`. The submitted own deletion defers, then `Accept_group` followed by replay successfully commits. This distinguishes the missing recovery owner from a database that cannot apply a valid deletion at all.

A correction will need to define how durable submitted batches are resolved after their connection/process ends, and ensure the corresponding authoritative deletion can resume. It must also avoid reporting `Current` while unresolved authoritative work remains. No such fix was made during this investigation.

## Repeatable local diagnostic command

From this worktree:

```sh
python3 docs/test-reports/reproductions/reproduce-sync-bugs.py
```

The script asks Dune for the dependency-loading directives, loads actual current source, and runs all three probes in disposable temporary fixtures. It does not authenticate or access the live graph. Success means the known defect assertions and control cases were reproduced, not that the defects are fixed. A future fix should cause the relevant defect assertion to fail until the diagnostic is updated into a regression test.

The script requires the repository's configured OPAM switch and dependencies. It deliberately avoids changing `dune`, public specs, or production source. [The filtered runtime trace](reproductions/2026-09-06-sync-trace.txt) contains event kinds, cursors, checksums, phases, and errors; transaction bodies, keys, and credentials are excluded.

## Validation and final state

- Three diagnostic probes: passed, including real worker/Core code and the overlay database control.
- Normal macOS Debug build after instrumentation removal: passed; app launched using the original application support directory.
- `opam exec -- dune build @all`: passed.
- `opam exec -- dune runtest`: passed; Dune reused existing valid test results where applicable.
- `ocamlformat --check` on 228 project OCaml source/interface files: passed.
- `git diff --check`: passed.
- Decision-document validation: passed.

The temporary edits to `logseq_db_worker/lib/logseq_db_worker.ml` and `flutter/lib/application_host_adapter.dart` were restored byte-for-byte from their pre-investigation copies. Existing working-tree and staged changes were preserved. No spec, dune, or bonsai_flutter OCaml file was modified.

The original mirror still has cursor 498 and its same three pending audit mutations. The three newly created online test markers were deleted successfully on the peer. The last post-interruption capture exists only in the disposable mirror. That isolated failed mirror and fuller diagnostic logs are retained under `/tmp/logseq-journal-macos-qa-20260906/` for follow-up; they are not used by the restored app. Sync remains broken until the code is corrected.
