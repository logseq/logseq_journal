# Complete Local Graph Deletion And Return To Graph Selection

## Problem

The UI action labelled `Delete and redownload local graph copy` sends
`Delete_local_cache` and immediately closes its confirmation surface. Core handles
`Local_cache_deletion_requested` by independently delegating `Delete_mirror` and,
when authenticated, issuing `Delete_wrapped_graph_key`. It does not cancel graph
effects, close the WebSocket, detach the open overlay database, advance graph
generations, move startup into a resetting state, or complete cleanup with an
acknowledged transition to graph selection.

The worker's `Delete_mirror` branch calls `Database.delete_mirror` without first
closing the attached database. `Database.delete_mirror` must acquire ownership of the
graph directory, so deletion of the currently open mirror returns busy. Wrapped-key
deletion proceeds independently and can succeed. The UI then silently returns to
Timeline with the database still open, its Keychain entry removed, and no redownload
in progress.

This is a partially ordered lifecycle operation over
Core state, the WebSocket, the attached overlay database, the durable mirror,
Keychain, and graph selection. Independent best-effort deletion creates split
states and lets stale completions target a graph while its local state is being
replaced.

## macOS reproduction and restart root cause (2026-09-06)

The existing macOS Debug app was tested with the encrypted `ocaml-sync-test`
graph. Before reset, Diagnostics showed `Sync = Current`, `Startup = Ready`,
and `Graph = Open`; a read-only SQLite query confirmed zero outbox records.
The test used Account > Reset local copy > Delete and redownload, then quit
and relaunched the same app bundle.

After reset, Timeline remained visible without a download. After relaunch,
the UI remained on `Restoring your graph`; Diagnostics showed `Sync = Failed`,
`Startup = Restoring local`, and `Graph = Closed`. The existing mirror was
still present, and the restarted process had no open mirror database handle.
The tested native framework was built on 2026-09-04 at 23:30; the investigation
also reproduced the reducer failure against the current worktree libraries.
No implementation files were changed or rebuilt into the running app.

Two defects combine to produce this result:

1. **Reset creates an inconsistent local state.** The selected database stays
   attached while `Delete_mirror` attempts to acquire its ownership lock.
   `Database.delete_mirror` rejects this as `Mirror_delete_busy`, which the
   worker replaces with a generic deletion error. Independently,
   `Delete_wrapped_graph_key` removes the cached key. Core neither awaits a
   successful ordered cleanup nor restarts bootstrap. The surviving encrypted
   mirror therefore cannot be reopened through the cached-key path after the
   in-memory graph key disappears at process exit.
2. **Authentication reconciliation erases the recovery failure.** On a warm
   launch, `Load_and_unlock_graph_key` failure calls `fail During_local_restore`,
   setting `sync_phase = Failed`, `startup.failure`, and `last_error`. A later
   `Account_authenticated` for the same user unconditionally clears both error
   fields in `authenticate` and `request_catalog_reconciliation`. The successful
   `catalog_refreshed` path clears them again. None of these operations retries
   mirror inspection, key loading, or graph attachment. `Journal_startup.derive`
   sees an authenticated account, a closed graph, and no reported failure; its
   default branch returns `Restoring_local`. The compact startup UI supplies no
   recovery action for that branch.

A temporary OCaml reproduction outside the repository evaluated the current
compiled reducer through `dune ocaml top logseq_sync`. It supplied a cached
selected encrypted graph and an available mirror, completed the local key
request with `wrappedGraphKeyUnavailable`, then delivered same-user
authentication and a successful catalog result. The observed states were:

| Event | Sync | Local-restore failure | Last error | Catalog loading |
| --- | --- | --- | --- | --- |
| Missing-key completion | Failed | Present | wrappedGraphKeyUnavailable | false |
| Same-user authentication | Failed | Absent | None | true |
| Catalog completion | Failed | Absent | None | false |

The reproduction asserted that the final sync phase remained failed, both
error fields were absent, and catalog completion emitted neither graph
attachment nor cached-key loading. This is a deterministic reproduction of
failure masking, independent of network delay. It explains the observed
`Failed / Restoring local / Closed` combination; it is distinct from the
previous calendar/feed-presentation stall with an already open graph.

The failure-preservation subproblem has since been fixed in
[Preserve Local Restore Failure During Reconciliation](../../implemented/bugfix/2026-09-06-preserve-local-restore-failure-during-reconciliation.md).
Its pure reducer regression covers the missing-key failure followed by same-user
authentication, successful catalog reconciliation, and explicit recovery. The
reproduction above records the historical failure; the incomplete deletion
lifecycle remains the scope of this decision.

## Proposal

On 2026-09-06, the user specified that fully closing and deleting the local graph
must lead to the graph selection screen. Deletion must not automatically download
or reopen that graph.

This is a debugging command, not a normal user recovery flow. It supports only the
currently selected, normally open graph. Deletion during graph download, snapshot
activation, or other startup phases is out of scope, as is deletion of an unselected
graph. Enforce this admission rule in the state owner as well as the UI.

Retain the cached wrapped graph key. This command must not emit
`Delete_wrapped_graph_key` or remove the graph's Keychain entry, on either success or
failure. A later explicit selection may reuse the retained key through the normal
graph-opening flow; missing or unusable keys follow that flow's existing E2EE access
handling. Retaining the key does not trigger automatic unlock or download.

Discard unsaved drafts and local unsynchronized changes directly. Do not save drafts,
flush the outbox to the server, wait for synchronization, or add a separate
unsynchronized-data confirmation flow. Already executing database operations must
still finish safely before their resources are closed; waiting for database closure
does not mean waiting for remote synchronization. This local command cannot undo
changes already received by the server.

Before implementation, inspect the existing graph close flow to establish whether
it stops admission of new work, waits for executing database operations to finish,
and releases the listener, database ownership, and related graph resources. Reuse
that flow and its existing guarantees directly, adding only missing guarantees.
Generation fencing rejects late events; it does not substitute for acknowledgment
that closure has completed. Do not expand the close flow to support deletion during
download or snapshot activation for this decision.

Replace the selected-graph UI command with an explicit reducer-owned local deletion
lifecycle. Rename the action and confirmation to `Delete local graph copy`, and
explain that completion returns to graph selection. This removes only the local
copy; the remote graph remains in the account catalog. Remove the obsolete
fire-and-forget path rather than retaining it as a fallback. The lifecycle should:

1. admit deletion only for the currently selected, normally open graph and capture
   its account and graph identities;
2. stop accepting new edits and sync operations, discard unsaved drafts, and advance
   the graph, connection, presentation, and lifecycle fences needed to reject late
   events from the old lifecycle;
3. invoke the existing graph close flow to stop scoped work and close the WebSocket;
4. await close completion confirming that executing database operations have ended
   and the listener, attached database, ownership, and related resources are released;
5. delete the durable mirror only after closure is confirmed;
6. clear the active graph selection and persist the removal of its saved selection
   only after required cleanup succeeds; and
7. finish on the graph selection screen after the selection update is acknowledged,
   with no automatic graph attachment, E2EE unlock, or snapshot bootstrap.

Keep deletion progress visible until the lifecycle completes. A later explicit
selection of the deleted graph starts the normal absent-mirror download flow,
including E2EE access when required. Selecting another graph follows its ordinary
opening flow. Ordinary launch still restores a valid saved selection as required by
`docs/ux-guidelines.md`; successful explicit deletion clears that selection so a
restart cannot automatically reopen or redownload the deleted local copy.

An application exit or crash before deletion and selection persistence complete may
leave the old saved selection intact. Restoring that selection on the next launch,
including the normal absent-mirror download if needed, is acceptable. Do not add a
durable deletion journal, crash recovery, rollback, or resumable cleanup for this
debugging command. The graph-selection terminal state applies to successful
completion, not interrupted execution.

Every transition and completion must carry the captured scope/generation. Any
failure stops the command and reports its stage-specific sanitized error. Do not
provide Retry, automatic retries, or recovery/resume stages. Do not report success
or silently show a ready Timeline after partial cleanup. Coalesce or reject repeated
requests while deletion is running so they cannot start duplicate cleanup.

Test the reducer ordering before implementation. Reproduce through the production
state owner's public pure events, completions, state, and effects first, following
`AGENTS.md`. Cover admission for only the normally open current graph, rejection of
new editing and sync work after admission, close-before-delete ordering, error
termination without retries, stale completion fencing, repeated requests, selection
clearing, preservation of the wrapped graph key, and absence of automatic bootstrap
with pure reducer tests wherever that boundary reproduces the defect. Use the
narrowest executing layer only for defects that cannot be reproduced there; do not
duplicate pure regression coverage in integration or UI tests. Manual macOS
validation should confirm deletion reaches graph selection and that downloading
starts only after a subsequent explicit graph selection.

## Implementation and verification record (2026-09-06)

The user authorized necessary `spec/` updates and requested a semantic audit of all
pure reducer tests after implementation.

The close-flow inspection found that `Database.close` already rejects new database
access, drains active snapshot reads and subscription callbacks, closes storage, and
releases directory ownership. `Database.unlisten` drains its running callback. These
guarantees are reused without changes to the overlay close implementation. The
worker reducer now stops admission and drains already-issued database requests and
sync worker operations before releasing `Detach_graph`. The runner propagates the
close result instead of discarding it.

Sync Core owns `Closing_graph`, `Deleting_mirror`, and `Clearing_selection`, with
scoped close/deletion completions and the existing typed catalog-save completion.
Failure terminates at its stage with a constant sanitized error and no retry.
Obsolete wrapped-key deletion requests and their runner callback dependency were
removed. The account sign-out cleanup remains supported and tested.

A separate executing-layer reproduction found that a cancelled queued runner
callback could still execute a synchronous `Save_catalog` before noticing its
cancel promise. That runner-owned scheduling defect cannot be reproduced by
injecting a pure Core completion. Its narrow runner regression submits a real
catalog-save effect, cancels its scope before executing the queued callback, and
asserts that no durable file is created. The runner now checks cancellation before
executing a request. No integration or UI tests duplicate the pure deletion ordering
regressions.

Completed verification so far:

- RED: unopened deletion admission, plain/encrypted ordering and failure stages,
  worker admission/drain ordering, UI-domain deletion failure projection, and queued
  runner cancellation each reproduced a behavior failure before their fix.
- GREEN: `dune build @all` and `dune runtest` passed; the Sync suite contains 135 tests.
- `python3 tool/test_macos_regressions.py` passed all three registered suites,
  including the standalone pure reducer mutation/editor/diagnostics tests.
- The final macOS Debug app was built through the installed `bonsai-flutter` tool.
- Manual macOS deletion reached graph selection with no open mirror handle and
  `selectedGraph: null`. Restart stayed at graph selection. Explicit selection alone
  started download; the encrypted graph reopened without another password prompt.
  A subsequent launch restored that newly selected graph normally.
- All pure reducer suites were audited for semantic consistency. Ordinary picker
  persistence and remote submission recovery retain their distinct semantics;
  obsolete local wrapped-key deletion expectations were removed.
- Final evidence and the complete test audit are recorded in
  [Local Graph Deletion Lifecycle Validation](../../../test-reports/2026-09-06-local-graph-deletion-lifecycle.md).

## Decision

Implement the selected-graph local deletion lifecycle as proposed. Sync Core owns
admission and the acknowledged close, mirror deletion, and selection persistence
stages. Reuse the existing database close guarantees, drain issued worker operations
before detach, retain the wrapped graph key, and require explicit graph selection
before any subsequent download. Reject duplicate or superseded work and terminate
failures without recovery stages. The implementation and validation above are
complete, including the requested pure reducer semantic audit.

## Alternatives considered

### Close the database inside `Delete_mirror`

The worker could special-case the attached graph and call `close_attached` immediately
before deletion.

A standalone close call in this branch leaves Core believing the graph is attached,
does not coordinate transport or pending work, and does not complete the transition
to graph selection. Reuse the existing coordinated graph close flow and acknowledge
its completion before deletion instead.

### Delete the wrapped graph key along with the mirror

The user chose to retain the wrapped graph key. Removing it would discard cached
E2EE access and add cross-store cleanup to this local database debugging command.
Neither sequential nor concurrent Keychain deletion is part of this lifecycle.

### Automatically redownload the deleted graph

This was the original proposal. The user chose graph selection as the successful
terminal state instead. Remove the automatic redownload promise from the action
label and require an explicit graph selection before starting another bootstrap.

### Restart the entire application

A process restart may happen to release database ownership, but it does not provide
operation ordering, error reporting, or testable stale-effect fencing. Deletion and
the transition to graph selection must complete inside one process.

## Acceptance criteria

- Deletion is admitted only for the currently selected, normally open graph.
  Unselected graphs and graphs downloading or activating snapshots are not supported.
- Unsaved drafts and local unsynchronized changes are discarded directly, without
  draft saving, a sync flush, or an additional unsynchronized-data confirmation.
- Once deletion starts, no new editing or sync work is admitted. Existing graph close
  guarantees are inspected before implementation and reused; only missing guarantees
  are added.
- Executing database operations finish and the listener, database ownership, and
  related resources are released before mirror deletion is attempted. Acknowledged
  close completion, rather than generation fencing alone, permits file deletion.
  Deletion no longer returns busy because the worker itself still owns the database.
- Old HTTP, WebSocket, overlay, and Keychain completions cannot reopen the deleted
  graph, leave graph selection, or mutate a subsequently selected graph lifecycle.
- The cached wrapped graph key and its Keychain entry are retained on success and
  failure. The command emits no `Delete_wrapped_graph_key` effect.
- A successful command closes and deletes the local copy, clears active and saved
  selection, and opens graph selection after cleanup and persistence complete. The
  remote graph remains available in the catalog.
- Completion emits no automatic `/pull`, E2EE unlock, snapshot activation, graph
  attachment, or Timeline opening. Explicitly selecting the deleted graph later
  starts the normal absent-mirror download flow.
- Deletion progress remains visible while running. A failure stops further steps and
  reports a stage-specific sanitized error, with no Retry action, automatic retry,
  rollback, or resumable recovery flow.
- Repeated activation of the command is coalesced or rejected without duplicate
  cleanup operations.
- Encrypted and unencrypted current graphs are covered at their production ownership
  boundaries under `AGENTS.md`; unsupported deletion requests are rejected.
- A macOS restart after successful deletion stays at graph selection when no new
  graph has been selected. Once a graph is explicitly selected and opened, subsequent
  launches restore that saved selection normally.
- If the process exits before cleanup and selection persistence complete, restoring
  the old saved selection on restart is acceptable. No crash-safe completion or
  durable recovery mechanism is required.

## Risks

- Mirror deletion and saved-selection persistence may partially complete. Partial
  failure is reported as an error; this debugging command does not attempt rollback
  or recovery.
- Closing the selected graph removes local availability until a graph is opened again;
  progress and error reporting must reflect the actual close and deletion state.
- Unsynchronized changes and drafts are intentionally lost. Interrupted deletion may
  leave a saved selection that normal launch restores; this behavior is accepted.
- Reusing a graph ID with advanced generations requires every completion path to
  validate scope rather than graph ID alone.
- The retained wrapped graph key preserves cached E2EE access. This command deletes
  the local database copy; it does not perform a full local security reset.

## Consequences

Successful deletion leaves no active or saved graph selection, while the remote
catalog and cached E2EE access remain available. Unsaved drafts and unsynchronized
local changes are intentionally discarded. Partial failure is visible at its stage;
interrupted execution may restore the old selection at next launch. There is no
rollback, retry, durable deletion journal, or compatibility path for the removed
wrapped-key deletion command. Ordinary explicit selection and warm launch continue
to use the existing graph-opening flow.

## Questions

- None. The user chose to retain the wrapped graph key on 2026-09-06.
