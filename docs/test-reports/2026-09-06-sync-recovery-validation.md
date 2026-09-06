# Sync Recovery Validation — 2026-09-06

## Scope

Follow-up to M02 in the macOS sync audit. The user authorized necessary spec edits
and chose to redownload the disposable encrypted `ocaml-sync-test` graph instead
of repairing its already-colliding historical batch receipt.

## Native evidence

| Observation | Result |
| --- | --- |
| Original mirror | Cursor 498, four pending records; Submitted ID `submission-batch:v1:2` overlaps an accepted receipt through 480 |
| Failure handling in rebuilt app | Diagnostics Failed / Ready / Open; all four records retained |
| Fresh downloaded mirror | Cursor 506, zero outbox records |
| First new Capture | `QA-SYNC-20260906 before-restart`, accepted through 507, outbox empty |
| Restart | Same graph restored and first marker visible |
| Second new Capture | `QA-SYNC-20260906 after-restart`, accepted through 508, outbox empty |
| Final read-only SQLite inspection | Cursor 509, zero outbox records |
| Final Diagnostics | Current / Ready / Open; outbox 0 / 4096, 0 B / 8 MB; protected payload and origin evidence 0 B |

The terminal accepted-batch IDs were distinct:

- First: `submission-batch:v1:b64a5ede-1ad9-40b6-847d-6d60d5807adf:1`.
- After restart: `submission-batch:v1:9120b587-85d4-46b3-8f00-58bfcb0ef92f:1`.

The first marker survived a process restart. The two acceptance receipts and empty
outbox establish server acceptance and authoritative incorporation, beyond a
locally optimistic Timeline. Cursor 509 includes subsequent authoritative catch-up;
it is not claimed as either marker's acceptance cursor.

## Reproduction and automated checks

- Eleven public pure Core recovery cases pass, including the original M02
  disconnect and fresh-process cases, acknowledgements/rejection, barriers,
  interrupted retry, timeout fencing, and exact-request failure handling.
- The frozen Retry_group baseline case failed before the repair and passed after.
- The Database reopen case failed on reused terminal batch identity before the
  allocator repair and passed afterwards, including an unchanged new submission
  after a duplicate old acknowledgement.
- Complete `dune runtest`: passed; Sync 129 cases, overlay sync 49 cases.
- `dune build @all`, existing macOS regression script, final native Debug build,
  formatting of 231 application/package/test OCaml files, diff whitespace checks,
  and decision validation passed. Three pre-existing standalone OCaml probes under
  docs/test-reports/reproductions remain unformatted and unchanged.
- Two transport setup races occurred on the first full run while reading the
  fixture's empty ready-port file; the complete rerun passed without changes.

Native tests exercise normal authoritative round trips across restart. Interrupted
Submitted response orderings are verified by the public pure cases; the original
already-corrupt queue was not silently repaired or reported as recovered.

## Reset limitation and retained evidence

The existing Reset local copy UI failed because it attempted mirror deletion while
its database was open. Its separate exploring decision remains outstanding. After
the user authorized redownload, the application was closed and its old graph
directory was moved intact, with no remaining open handles. Continue online then
started fresh download; the user entered the encryption password directly in the
application. No key or password was read into this report.

Retained outside the repository:

- SQLite backup before reset:
  `/var/folders/hg/17vhljys4xj_5q9flnswd0jm0000gn/T/journal-before-redownload-uzpx19f0/db.sqlite`.
- Complete old graph directory:
  `/var/folders/hg/17vhljys4xj_5q9flnswd0jm0000gn/T/journal-retired-test-mirror-8tn5fqjo/graph`.

Temporary payload-free worker instrumentation was removed byte-for-byte before
building the final app. No receipt was directly edited, no compatibility or
migration path was added, and no test marker outside this test graph was changed.
