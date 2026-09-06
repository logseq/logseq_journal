# Local Graph Deletion Lifecycle Validation

## Scope

Implement the approved local-copy deletion decision, including necessary public
`spec/` updates, and audit all pure reducer test suites for semantic consistency.
The worktree already contained staged and unstaged work; this validation uses the
combined worktree without resetting or committing those changes. No dune files or
OCaml files in the bonsai_flutter repository were modified by this task.

## Ownership and implementation

- Sync Core admits only the selected, authenticated, normally open graph. It owns
  `Closing_graph`, `Deleting_mirror`, and `Clearing_selection`; failures retain their
  stage and a constant sanitized message. Repeated requests and graph/startup/sync
  events cannot resume or duplicate an admitted deletion.
- The worker reducer immediately changes admission to `Graph_closing`. It waits for
  every already-issued database request and delegated sync database operation to
  complete before running the existing `Detach_graph`. Late completions still drain
  their exact pending tickets, but cannot reopen the old lifecycle.
- Existing `Database.unlisten` and `Database.close` drain callbacks and active
  snapshot reads, close storage, and release directory ownership. These existing
  implementations were inspected and reused. Close errors are now propagated.
- Scoped close success enables mirror deletion. Scoped mirror success clears active
  selection and emits a catalog save with no selected graph. Its typed completion
  alone enables graph selection. Cleanup does not unlock, attach, activate a
  snapshot, submit local changes, or remove a wrapped key.
- The app discards Capture/detail drafts and pending local UI actions at admission,
  resets pending projection requests, hides editing, and displays the current
  deletion stage. Failure has no Retry control. Diagnostics remain accessible.
  Quitting during deletion can interrupt cleanup, as allowed by the decision.

Two additional ownership boundaries are covered narrowly. Startup presentation is
owned by `Journal_startup.derive`: a valid deletion-failure snapshot must override a
stale open-graph presentation and expose no recovery action. The runner owns queued
callback execution: a cancelled catalog-save callback must not write an old saved
selection even when its scheduled fiber has not started. Supplying a pure Core
completion cannot reproduce that filesystem side effect; its regression therefore
executes only the runner with a controlled queue and temporary local storage.

## RED and GREEN evidence

Before the corresponding fixes, executable tests failed on:

1. Deletion admitted for an unopened graph.
2. Missing deletion stages and close-before-delete ordering for both plain and
   encrypted graphs.
3. Missing terminal failure handling at close, mirror deletion, and selection save.
4. Worker admission remaining open while deletion was requested.
5. Startup presentation reporting Ready for a deletion failure.
6. A cancelled queued catalog save still creating its durable directory/file.

After implementation, the pure tests cover unsupported snapshot download,
activation, reinspection, attachment, and encrypted key-loading states; rejection of
new editing and sync work; draining existing worker operations; captured scopes and
advanced generations; stale and duplicate completions; stage failures; saved and
active selection removal; no key/bootstrap requests during cleanup; restart with an
empty selection; and subsequent explicit selection of the same or another graph.

Verification commands:

- `dune build @all`
- `dune runtest`
- `python3 tool/test_macos_regressions.py`
- `ocamlformat --check` on every OCaml file changed by this task
- `git diff --check`
- `spec-dev-tool check --all`
- Installed `bonsai-flutter build macos --profile=debug`

The Sync executable runs 135 cases. Its public reducer groups contain 39 core cases
(including BC01–BC10 and local-restore reconciliation) and 11 recovery cases. The
worker reducer runs five cases. The standalone macOS pure reducer suite runs nine
cases; its companion application-dispatch and runtime suites also pass.

One repeat of the full suite encountered an existing transport-test readiness race:
`with_peer` observes that the Python peer's `ready` file exists, then reads it before
the port text has been written; `int_of_string` failed at transport_contract.ml:151.
The isolated transport case passed on recheck without production changes. The full suite passed again without modifying this unrelated test harness.

## Pure reducer semantic audit

| Files or group | Semantic assessment |
| --- | --- |
| `logseq_sync/test/core_contract.ml`, canonical happy path | Expected states, effect identities, and effect order still follow public startup, attachment, pull, outbox reservation, acknowledgement, and authoritative application transitions. Replay checks preserve the source state. |
| Catalog selection and persistence cases | Ordinary graph-picker navigation intentionally retains the saved selection. Local deletion explicitly clears it after cleanup. Best-effort save failure for ordinary selection remains distinct from terminal deletion-save failure. |
| Encrypted restore/bootstrap and sign-out cases | Cached-key loading, explicit E2EE recovery, and account cleanup remain valid. The obsolete local-cache test expecting anonymous/unselected deletion and wrapped-key removal was replaced with admission and lifecycle tests. |
| `pure_reducer_bad_case_01.ml` through `pure_reducer_bad_case_10.ml` and their support | Unowned progress, duplicate mirror/attachment/socket completions, closed/replaced connections, unsolicited authoritative/sync results, stale account tickets, and mismatched outbox transitions are rejected while the matching owner remains usable. Their fixtures use the public event/completion boundary. |
| Sync recovery reproduction cases in `core_contract.ml` | Submitted/accepted/rejected outbox barriers, disconnect/restart recovery, retry correlation, timeout fencing, and failures still describe remote synchronization recovery. Those retry rules are not applied to the local deletion command. |
| `local_restore_failure_reconciliation.ml` | A correct missing-key failure survives same-user authentication and catalog success until explicit recovery. Retaining wrapped keys during deletion does not invalidate this independent startup failure case. |
| `logseq_db_worker/test/test_pure_reducer.ml` | Serial state transitions, reply identity, deterministic replay, graph admission, and draining of concurrent issued effects are asserted through public worker events and completions. The new editing request is rejected before execution. |
| `test/macos_mutation_input_diagnostics_pure_reducer_test.ml` | All nine existing editor, Capture, detail-session replacement/discard, undo/reconciliation, and admission-request correlation cases remain semantically valid and pass through the registered runner. |

The existing runner account-secret success/error tests were retained and updated to
exercise the supported account cleanup operation. Their now-obsolete per-graph
wrapped-key deletion branch and callback dependency were removed, rather than
manufacturing an unreachable effect ticket or keeping a compatibility path.

## Manual macOS validation

Date: 2026-09-06, approximately 18:20–18:35 Asia/Shanghai.
App: `flutter/build/macos/Build/Products/Debug/bonsai_flutter_logseq_journal_host.app`.
Graph: encrypted `ocaml-sync-test`, `b49df932-9915-468d-a190-8f769d40ff0b`.

1. Before deletion, actual Diagnostics showed Current / Ready / Open and zero outbox
   records. No remote records were created or deleted during this validation.
2. Account exposes `Delete local graph copy`. Its confirmation states that local
   drafts/pending changes are discarded, the remote graph and cached encryption key
   are retained, and completion returns to graph selection.
3. Confirming deletion reached `Choose a graph` in the same process. The original
   graph remained in the authorized catalog. A read-only filesystem check confirmed
   its `db.sqlite` was absent; `lsof` found no attached graph database. The current
   catalog cache had `selectedGraph: null`.
4. Quitting and relaunching without selecting a graph remained at `Choose a graph`.
5. Only explicitly selecting `ocaml-sync-test` changed the UI to `Downloading graph`.
   Download and attachment completed successfully and Timeline returned without
   another E2EE password prompt. The recreated mirror exists, and the cache again
   contains the explicitly selected graph ID.
6. A further launch of the final Debug build returned directly to Timeline with the
   same graph, confirming normal warm restoration after an explicit selection.

A disposable unsaved Capture draft was inspected while exercising the UI, but an
intermediate app restart discarded that draft before the successful deletion run;
that observation is not claimed as a direct manual proof of deletion discarding a
draft. Draft discard is evidenced by the app admission transition and existing
session/request fencing tests. Fast successful cleanup did not expose every
intermediate progress label long enough for manual observation; their ordering is
covered by the pure state-machine tests.
