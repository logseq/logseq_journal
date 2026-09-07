# Todo Capture and Stale Sync Recovery Verification

Date: 2026-09-07

## Result

The implementation passes its focused tests, the full project build, and the full test alias. A subsequent [live macOS Release check](macos-release.md) passes Todo Capture across restart, subsequent status changes, peer convergence, and cleanup with an empty outbox. A live server Stale rejection was not observed.

| Check | Result |
| --- | --- |
| Original implementation with the 38 new public Database regressions | 38 expected failures; exit 1 |
| `opam exec -- dune exec test/journal_timeline_state_test.exe` | Passed; exit 0 |
| `opam exec -- dune exec logseq_overlay_db/test/test_overlay_sync.exe` | 87 tests passed; exit 0 |
| `opam exec -- dune exec logseq_sync/test/test_sync.exe -- test 'sync recovery reproductions'` | 11 tests passed; exit 0 |
| `opam exec -- dune build @all` | Passed; exit 0 |
| `opam exec -- dune runtest` | Final run passed; exit 0 |
| `opam exec -- ocamlformat --check` on the 12 touched OCaml files | Passed; exit 0 |
| `git diff --check` | Passed; exit 0 |
| `git apply --reverse --check /tmp/todo-capture-baseline.patch` | Passed; all pre-existing worktree patch hunks remain present |
| `spec-dev-tool check --all` | Passed |

## Regression evidence

The timeline test first failed with three copies of the same captured block UUID after repeated completion. Its final passing test preserves expanded child slots, day/feed continuations, counts, updated entry content, and Reset_to_top; it also covers completion before page reconciliation.

The [Database RED run](overlay-red.log) reconstructs the exact starting production implementation, including the unrelated worktree changes already present at task start. All 38 new cases fail. The six temporarily replaced production/interface files were restored byte-for-byte in a `finally` block before final verification.

The [Database GREEN run](overlay-green.log) passes 87 tests. The new cases cover all five ordinary mutation kinds, barriers ahead of/equal to/behind the checkpoint, original execution versus non-execution, repeated pending and terminal rejection, a fresh attempt and baseline, dependent queued work, missing dependencies, conflicting insertion UUIDs, superseding batch members, wrong cursor attribution, missing original batch-prefix evidence, non-advancing rejection barriers, and equivalent content producing No_change without proving execution. Existing delete outcomes and byte-identical uncertain retries continue to pass.

All new bug regressions use the existing public Timeline or Database ownership boundary. No duplicate effect-runner, transport, persistence, integration, E2E, or UI regression suite was added. Sync's existing fixtures only received the transport-state constructor rename.

## Full-suite retry

The [initial full run](full-suite-initial.log) encountered one transient failure in the unmodified HTTP malformed-chunk transport fixture. `transport_contract.ml:151` called `int_of_string` while reading the test peer's ready file; readiness checks only file existence, while the peer creates then writes the numeric port. This is consistent with reading an empty file during startup.

The [isolated case](transport-retest.log) passed immediately. A complete Sync rerun passed all 135 tests, and the [final full test alias](full-suite-final.log) passed. No transport source or fixture change was made.

Additional focused evidence: [Timeline](timeline-green.log), [Sync recovery](sync-recovery.log).

## Scope and limitations

- The general pending state and encoding replace the obsolete delete-specific state without compatibility readers or migrations.
- Only the authorized Overlay spec `.mli` declarations/documentation were changed for this repair. No dune files or bonsai_flutter OCaml files were modified.
- Automated Database fixtures use disposable directories. The subsequent live check created and deleted two uniquely identified test records through the native UI; no graph reset, direct database mutation, or original user-record edit was performed.
- Live Todo Capture across restart, peer convergence, and live outbox emptiness passed in the linked Release report. Recovery from a deliberately triggered live Stale rejection or lost acknowledgment remains unverified.
