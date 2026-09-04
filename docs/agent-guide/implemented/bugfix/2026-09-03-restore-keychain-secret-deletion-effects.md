# Restore Keychain Secret Deletion Effects

## Problem

The Apple secrets adapter implements both lifecycle deletion operations required
by the Keychain-backed wrapped-key architecture:

- `delete_wrapped_graph_key` deletes one account-and-graph-scoped wrapped key;
- `delete_account_secrets` deletes every wrapped graph key for an account and its
  retained private key.

The Sync Effect Runner stores those callbacks, but no `Core.runner_request` can
reach either one. `Core.sign_out` currently resets the managed worker account and
clears reducer state without deleting account secrets.
`Local_cache_deletion_requested` delegates only `Delete_mirror`, leaving the
graph's wrapped key in Keychain. The `ignore` expressions in
`Effect_runner.dependencies` hide the missing behavior by making the callbacks
look intentionally retained.

This is a lifecycle defect rather than unused dependency surface. The implemented
Keychain decision requires explicit sign-out to delete the old account's secrets
and explicit local-cache deletion to delete that graph's wrapped key. Identity
scoping prevents a leftover item from being read by another account, but it does
not make the requested deletion happen.

Sign-out also lacks the ordering boundary required for safe cleanup. It clears
`pending_effects` without first cancelling the old account scope, while Keychain
writes execute asynchronously in runner fibers. Merely dispatching account
deletion concurrently could allow an earlier `unlock_private_key` or
`verify_and_save_wrapped_graph_key` operation to finish after deletion and restore
the secret that sign-out was meant to remove.

## Proposal

Extend the typed runner protocol with two unit-returning requests:

- `Delete_wrapped_graph_key` carries a captured `account_scope` and `graph_id`;
- `Delete_account_secrets` carries the captured old `account_scope`.

Their request kinds exist only to correlate completion. The Effect Runner maps
the requests directly to the retained platform callbacks using
`managed_sync_origin`, `user_id`, and, for graph deletion, `graph_id`. Remove the
corresponding `ignore` expressions once both callbacks have real execution paths.
Do not expose Keychain identifiers or secret bytes through Core.

Treat all platform secret operations that load, create, replace, or delete
Keychain state as one serialized local action stream. At minimum this includes
`unlock_private_key`, `load_wrapped_graph_key`,
`verify_and_save_wrapped_graph_key`, `delete_wrapped_graph_key`, and
`delete_account_secrets`. The serialization boundary belongs to the Effect Runner;
Core continues to own identity, generation, and action ordering.

For an authenticated sign-out:

1. capture the old `account_scope` before changing reducer state;
2. synchronously produce a next state that clears account and graph access and
   advances account and presentation generations instead of resetting generations
   to reusable initial values;
3. submit `Cancel_effects` for the captured account scope before any cleanup
   request, so old account and graph work cannot publish a later completion;
4. reset the managed worker account using the captured scope;
5. issue exactly one `Delete_account_secrets` request for the captured identity;
   and
6. publish the signed-out state without waiting for Keychain I/O.

The deletion is queued behind any secret operation already inside the serialized
runner boundary. Its completion is cleanup-only: success consumes the ticket and
changes no product state; failure records and publishes a sanitized cleanup error
without restoring authentication, selecting a graph, or granting access to the old
account. A later authentication event may forget the old ticket, but it cannot
cancel or reinterpret the already submitted deletion as work for the new account.
Signing out while no account is bound emits no account-deletion request.

For `Local_cache_deletion_requested graph_id`, capture the currently authenticated
account identity independently of the current graph scope. When an account exists,
issue exactly one `Delete_wrapped_graph_key` request for that account and the
requested graph alongside the existing mirror-deletion lifecycle. This applies to
both the selected graph and another graph in the local catalog; the deletion
request must not substitute the selected graph's identifier for the requested
identifier. When no account identity exists, Core cannot construct a valid
Keychain identity and delegates only mirror deletion.

Graph-key deletion is idempotent and does not wait for mirror deletion or make
mirror deletion conditional on Keychain success. A success completion changes no
graph state. A failure publishes a sanitized cleanup error and leaves the existing
local-cache deletion command available for explicit retry; it must not reveal a
Keychain service, account digest, item label, or secret value.

Add public-contract coverage before implementation:

- pure-Core tests prove the exact captured identities, generation advancement,
  cancellation-before-account-deletion ordering, no-account behavior, and inert
  late completions;
- runner-contract tests prove each request invokes its callback exactly once,
  maps callback errors to typed effect failure, and contains no placeholder
  `ignore`; and
- a controlled concurrency test holds an earlier secret write open, starts
  sign-out deletion, then proves the delete executes after that write and no old
  write can repopulate Keychain after cleanup.

The change is a direct protocol cutover. Do not add optional callbacks, fallback
cleanup, legacy request aliases, or compatibility overloads.

## Decision

Restore both required deletion paths. Explicit sign-out invokes
`delete_account_secrets` for the captured old account after invalidating that
account's reducer scope, and explicit local-cache deletion invokes
`delete_wrapped_graph_key` for the authenticated account and requested graph.

Serialize Keychain-backed secret actions in the Effect Runner so account cleanup
cannot be overtaken by an older write. Cleanup completions may report sanitized
diagnostics only and cannot mutate replacement account or graph state.

## Alternatives considered

### Delete the callbacks as unused dependencies

Rejected. Unlike the removed `has_private_key` probe, these callbacks implement
explicitly adopted secret-lifecycle behavior. Their absent runner requests are the
defect this decision repairs.

### Call platform deletion directly from the reducer or worker

Rejected. Core must remain pure, and the database worker does not own Keychain
state. Typed runner requests preserve the existing ownership boundary and make
effect identity and completion testable.

### Fire deletion concurrently without serializing secret operations

Rejected. Cancellation suppresses stale completions but does not by itself prove
that a synchronous platform write already executing in another runner fiber cannot
finish after deletion. One local serialization boundary provides the required
write-before-delete order.

### Block sign-out until Keychain deletion succeeds

Rejected. Sign-out must revoke in-memory access immediately. A Keychain failure is
a cleanup failure to diagnose and retry, not authority to keep the user signed in.

### Make mirror deletion conditional on wrapped-key deletion

Rejected. Both operations are idempotent cleanup over independently owned stores.
Failing one must remain observable, but it must not prevent the other from removing
local state.

## Acceptance criteria

- `Core.runner_request` has typed execution paths for graph-scoped wrapped-key
  deletion and account-scoped secret deletion.
- An authenticated sign-out advances the account generation, clears access
  immediately, cancels old scoped work, and invokes `delete_account_secrets`
  exactly once with the captured origin and user ID.
- Account deletion is serialized after earlier Keychain writes, and no older write
  can recreate an account secret after the deletion completes.
- A sign-out completion, including one delivered after another account authenticates,
  cannot modify or fail the replacement account.
- Explicit local-cache deletion invokes `delete_wrapped_graph_key` exactly once
  with the authenticated origin, user ID, and requested graph ID, while retaining
  the existing mirror-deletion behavior.
- Local-cache deletion without an authenticated account does not invent a
  Keychain identity and still delegates mirror deletion.
- Successful cleanup completions are state-inert. Failed cleanup publishes only a
  sanitized, non-secret diagnostic and never restores access.
- The deletion callbacks are no longer referenced only by constructor plumbing or
  `ignore` expressions.
- Focused pure-reducer, runner, worker, and Apple platform tests pass, followed by
  `dune runtest logseq_sync/test`, `dune runtest logseq_db_worker/test`,
  `dune build @all`, `dune build @fmt`, `git diff --check`, and
  `spec-dev-tool check --all`.

## Risks

- Serializing Keychain operations can delay cleanup behind an in-progress unlock
  or save. Sign-out state must still become inaccessible immediately while the
  bounded cleanup continues.
- A failed account deletion can leave inaccessible orphaned Keychain items. The
  failure is intentionally diagnostic and retryable rather than a reason to undo
  sign-out.
- Account replacement and authoritative graph revocation have related deletion
  requirements in the broader Keychain architecture, but this bugfix is limited to
  the two paths explicitly authorized here: sign-out and explicit local-cache
  deletion. Those other lifecycle triggers require separate implementation work.
- Exact effect-list assertions can overfit publication order. Tests should require
  cancellation before cleanup and correct identity while ignoring unrelated
  diagnostic publication placement.

## Consequences

Core now issues typed account- and graph-scoped secret deletion requests. An
authenticated sign-out advances the account and presentation generations, clears
access immediately, cancels the captured old account scope, resets the managed
worker account, and submits account-secret deletion before publishing the
signed-out state. Explicit local-cache deletion submits wrapped-key deletion for
the authenticated account and the requested graph independently of mirror
deletion.

The Effect Runner now serializes every Keychain-backed load, unlock, save, and
delete action through one local mutex. Cleanup success only consumes its ticket;
cleanup failure publishes a fixed non-secret diagnostic and cannot restore or
fail a replacement account. Pure-Core, runner callback, typed-error, and
controlled-concurrency regression tests cover these boundaries.

Implementation completed on 2026-09-03. The focused sync and worker suites, root
tests including the Apple crypto lane, `dune build @all`, `dune build @fmt`, and
`git diff --check` passed.

## Questions

- None. The user explicitly authorized both deletions, and the implemented
  Keychain architecture already defines their identity and lifecycle semantics.
