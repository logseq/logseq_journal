# Session-scoped deletion Undo and Redo contract

## Disposition

On 2026-09-17, the user deferred new Undo/Redo implementation. UI-25 is outside
the current implementation scope; existing timed deletion cancellation remains.
No protected spec edits are authorized. This proposal is retained for future
reconsideration, not rejected on technical merits. Other UI standardization work
can proceed independently.

## Problem

UI-25 in [Native SwiftUI UI Standardization for iPhone](../../implemented/feature/2026-09-16-native-swiftui-ui-standardization.md)
requires deletion Undo and Redo for the current open-graph session, including the
affected descendants, after the transient notice expires. The existing application
only stages a deletion temporarily; its Undo cancels the scheduled admission.
Once deletion commits, that application-only mechanism cannot restore the graph.

Read-only inspection on 2026-09-17 established a protected-interface gap:

- `logseq_overlay_db/spec/types.mli:231` defines `block_tree` with only UUID,
  title and children. `Insert_blocks` takes that tree and a parent. There is no
  inverse-deletion mutation or session history capability in `local_mutation`.
- `logseq_overlay_db/spec/types.mli:273` returns mutation identity, status,
  generation, projection revisions and change summary in `local_commit`.
  It does not expose an opaque handle to the admitted deletion's inverse.
- `logseq_overlay_db/spec/database.mli:348` makes the database the serialized
  owner of validation, semantic freezing, durable admission and publication.
  Lines 369–372 explicitly freeze the latest subtree, including descendants
  added since the caller's earlier read. `commit_local` therefore knows the
  actual removed footprint; an application pre-read does not necessarily do so.
- The public database boundary has no Undo/Redo operation. `retry_blocked` and
  `discard_blocked` manage blocked mutations, not successful deletion inverses.
- Existing deletion conflict categories explicitly include incoming references,
  auxiliary holders, rewritten source titles, timestamps and page lifecycle.
  Reconstructing only UUID/title/children does not establish faithful reversal
  of these effects or preservation of unrelated later changes.

The repository requires development to stop when protected spec definitions
block implementation. No production code, tests, Dune files or protected OCaml
files were changed during this audit. That pause ended when the user deferred
UI-25; the remaining UI requirements still apply.

## Proposal

Authorize a contract change in exactly these protected interfaces first:

1. `logseq_overlay_db/spec/types.mli`
2. `logseq_overlay_db/spec/database.mli`

The database must own deletion history evidence. Add an opaque, session-bound
history token obtained from the successful serialized deletion admission, and a
serialized compensating operation that consumes it. The application keeps only
the ordered history/token references needed for native UndoManager and a
persistent touch-accessible Undo/Redo action. It does not own a copied subtree
or submit arbitrary inverse datoms.

### Proposed interface shape

The following is a reviewable contract sketch, not an applied edit. Declaration
order must follow the existing type dependencies.

```ocaml
(* Types: declare before local_commit. *)
type delete_history_token

type delete_history_action =
  | Undo_deletion
  | Redo_deletion

val delete_history_action : delete_history_token -> delete_history_action

(* Add to local_commit. None for unrelated mutations and admissions that did
   not produce a reversible deletion in the current open session. *)
(* ; delete_history : delete_history_token option *)

(* Types: declare after local_commit_outcome and local_commit_error. *)
type delete_history_error =
  | History_session_mismatch
  | History_invalidated
  | History_pending_settlement
  | History_conflict of delete_conflict_kind_set
  | History_identity_conflict of Graph.Uuid.t
  | History_commit_failed of local_commit_error

type delete_history_commit =
  { outcome : local_commit_outcome
  ; next : delete_history_token
  }

(* Database: the token carries the original footprint and the current inverse
   read conditions; the caller does not manufacture a replacement read set. *)
val commit_delete_history
  :  t
  -> mutation_id:Graph.Uuid.t
  -> token:Types.delete_history_token
  -> (Types.delete_history_commit, Types.delete_history_error) result
```

Worker protocol transport will need an opaque session handle for the token.
Prefer a worker-owned handle map to exporting the underlying deletion evidence.
A handle is valid only in its originating open database/graph session; parsing a
handle must not grant access to another session's history. No persistence or
restart restoration of the application history is proposed.

### Required semantics

- Capture the exact reversible semantic footprint in the same serialized
  operation that admits deletion, including concurrently added descendants.
- Undo must restore the deleted identities, hierarchy/order, owned properties
  and relevant auxiliary effects while preserving unrelated subsequent work.
  Define the inverse explicitly; blindly replaying old database datoms is not
  an acceptable contract.
- Validate the current logical state before compensation. Missing parents,
  reused UUIDs, changed references or conflicting auxiliary facts produce typed
  failures. No partial restoration may be published.
- Redo is the inverse of the admitted Undo, with a new mutation identity and
  fresh conflict checks. Successful compensation returns the next inverse token.
- Reusing the same operation ID for the same token is idempotent. Reusing it for
  different intent is rejected. Failed admission leaves history retryable where
  the failure permits; it must not advance the UI stack as if successful.
- Define behavior for queued, submitted, accepted, authoritatively incorporated,
  remote-won and blocked deletion outcomes. A token must not imply proven server
  execution. Pending uncertainty may return `History_pending_settlement`;
  remote conflict invalidation must remain explicit.
- Integrate compensation with normal outbox persistence, encryption, replay,
  synchronization and conflict handling. Verify the server-compatible transaction
  encoding before implementation is considered complete. The two proposed spec
  edits are the starting boundary, not a claim that only two files need work.
- Changing graphs, reopening the database or restarting invalidates tokens.
  Account changes also clear the application history. This never clears retained
  Capture/Append drafts solely because deletion history is cleared.
- Retain history evidence only for the live session and within explicit resource
  limits. Any history truncation must be surfaced rather than silently converting
  the confirmed session lifetime into a short timed recovery window.

Implementation should use the existing public production owners for deterministic
regressions. Test ownership must be identified before adding cases; missing
semantic ownership is not a reason to duplicate reducer behavior across layers.

## Questions

- Q1: May implementation modify `logseq_overlay_db/spec/types.mli` and
  `logseq_overlay_db/spec/database.mli` to add the session-bound deletion history
  contract described above? No protected spec edits have been made.
  Answer: Deferred by the user on 2026-09-17. Do not implement new Undo/Redo or
  modify these protected interfaces for it during the current work.

## Acceptance criteria

- The user explicitly authorizes the two protected `.mli` edits before any are made.
- The protected contract defines complete inverse ownership, session lifetime,
  idempotency, conflict behavior, resource limits and synchronization semantics.
- Deterministic public-owner tests cover complete subtree/metadata restoration,
  late descendants, unrelated later edits, identity conflicts, failed retry,
  duplicate completion, Redo, graph replacement and stale tokens.
- Native UndoManager and a reachable touch action use the owned history and only
  advance after the corresponding admitted result. Notice expiry does not clear it.
- The full UI decision remains open until all of its independent requirements
  and device/performance gates are satisfied.

## Risks

- This is a database and synchronization contract change, not a UI-only change.
- Frozen deletion artifacts might not currently retain every inverse fact; the
  implementation must audit and extend their ownership rather than infer missing
  data in the application.
- Undo/Redo history can retain private graph content and grow during a session.
  Limits, reclamation and graph/account teardown need explicit coverage.
- If further protected interfaces prove necessary, report the exact additional
  changes before editing them. Dune and bonsai_flutter restrictions remain intact.

## Alternatives considered

### Reinsert a tree captured by the UI before deletion

Rejected. The UI may not have loaded every descendant, and the serialized delete
may include newer descendants. The insertion tree cannot represent the complete
restoration footprint or validate its inverse against later changes.

### Keep deletion uncommitted until the graph closes

Rejected. This changes graph mutation/synchronization semantics and still leaves
no faithful committed-delete inverse. It replaces the requested capability with
a longer scheduling delay.

### Use raw database transactions or internal outbox structures

Rejected. The public database contract deliberately hides those internals. This
would bypass the protected ownership and validation boundary instead of fixing it.

### Extend only the timed Undo notice or add decorative native controls

Rejected. This does not provide session-scoped Undo/Redo after admission.

## Rejection reason

The user deferred Undo/Redo implementation on 2026-09-17; no protected spec edits are authorized.
