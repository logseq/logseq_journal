# Todo Capture macOS Release Verification

Date: 2026-09-07, Asia/Shanghai

## Result

The current worktree's macOS Release passes live Todo Capture, restart persistence, subsequent status changes, peer convergence, and cleanup. No duplicate-key crash occurred. The final restarted application reports Current / Ready / Open with an empty outbox.

This run did not observe a server Stale rejection or demonstrate recovery after a lost acknowledgment. The deterministic Database regressions in [the implementation report](report.md) cover those transitions; this live check does not replace them.

## Build and environment

- Built with `opam exec -- bonsai-flutter build macos --profile=release`; exit 0, Release app 57.7 MB.
- Quit the previously running application, then launched the newly built `flutter/build/macos/Build/Products/Release/bonsai_flutter_logseq_journal_host.app` by its full path.
- Executable SHA-256: `87503f64b941d4917728289f74145236c598cc1cd4cef0e688ec8cf04479e8d7`.
- Timeline source SHA-256: `d524449741157a4d9de55abb135c6b254288ae60b04b2828ea6e441d8e6c9b09`.
- Database source SHA-256: `decaeeaa6a6b2faa622f7d7bd493a52792526f4afb306a70da5967f235b12843`.
- All three hashes remained unchanged at the end of the run.
- Live graph: Lambda-RTC-test, UUID `f5271dfc-897a-43c7-b116-04832d13b70b`.
- Independent peer: the existing Chrome Logseq session at `https://app.logseq.com/#/`, displaying the same graph.
- Native UI operations used accessibility and screenshots. Database inspection used read-only SQLite connections and private backups. No mirror reset, redownload, direct database mutation, or original user-record edit was performed.

## Observed operations

All disposable titles used prefix `QA-TODO-FIX-20260907-2006`. The prefix is an identifier, not a timing measurement.

| Operation | Native observation | Peer and durable observation |
| --- | --- | --- |
| Initial launch | Opened the recent graph directly; diagnostics Current / Ready / Open | Outbox empty |
| Capture `todo-before-restart` with task intent enabled | One Todo row; no crash; Save-to-accessibility observation 951 ms | Exact row and Todo indicator appeared on peer; checkpoint 61, outbox empty at 19:53:43 |
| Quit and relaunch | Returned directly to the recent graph; first Todo retained | No graph selection required |
| Capture `todo-after-restart` with task intent enabled | One Todo row; no crash; Save-to-accessibility observation 942 ms | Exact row and Todo indicator appeared on peer; checkpoint 63, outbox empty at 19:55:46 |
| Relaunch and change second Todo to Doing through the native status picker | Second row showed Doing | Peer showed the Doing indicator |
| Delete second, then first test row through native swipe actions | Each row disappeared; deletion Undo windows expired | Both rows disappeared from peer |
| Final quit and relaunch | Recent graph opened directly; test rows did not reappear; original three rows for September 7 remained visible | Checkpoint 66, empty outbox, no error; diagnostics Current / Ready / Open |

The Capture timings include UI automation and accessibility observation. They are not renderer-only latency measurements. Launch and screenshot observations were separate calls, so no precise launch-to-readable-UI timing is asserted.

The two created block UUIDs were:

- `todo-before-restart`: `01a07bb7-64b1-8340-a18b-2e51ffbc7491`.
- `todo-after-restart`: `01a07bb9-4380-8c6a-bc3b-9ef793bf6cd6`.

## Final durable state

At 20:02:30, after cleanup and the final restart:

| Field | Value |
| --- | --- |
| Applied server cursor | 66 |
| Checksum | `24fd633bdc0d2437` |
| Status | `active` |
| Last error | `null` |
| Outbox records | 0 |
| SQLite integrity check | `ok` |

Native diagnostics additionally showed outbox bytes 0 B, protected payload 0 B, and origin evidence 0 B. The final pre-restart snapshot contained seven new applied mutation receipts compared with the baseline, consistent with two insert/status pairs, one status edit, and two deletes. No Stale batch receipt was observed.

The initial local mirror was at cursor 52 while the peer already contained newer original records. The mirror caught up during the test. Therefore baseline and final checksum equality is not a valid cleanup criterion; cleanup was checked by the exact test identities on both UIs, final restart, and settled local state.

## Interrupted-submit attempt and limits

An additional plain Capture titled `restart-during-submit` was followed immediately by application quit, approximately 244 ms after starting the Save action. No Save completion or durable admission was observed. The subsequent snapshot remained at cursor 63 with an empty outbox, and neither the restarted native app nor the peer showed that title.

This attempt stopped before demonstrated durable admission. It does not reproduce an in-flight acknowledgment loss, prove Stale settlement, or establish a data-loss defect. No third durable test record was observed. The historical acknowledgment interruption remains unexplained.

The live result establishes that ordinary Todo writes, restart, subsequent edits, and deletion converge in this Release. A deliberately triggered server Stale rejection remains unverified end to end.

Private raw evidence is retained locally under `/tmp/logseq-todo-fix-macos-20260907/` (baseline/final SQLite backups, source hashes, and checkpoint snapshots). The build log is `/tmp/todo-macos-release-build.log`. Full graph backups are intentionally not added to the repository.
