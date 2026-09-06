# Preserve Local Restore Failure During Reconciliation

## Problem

A selected encrypted graph can fail local restoration because its cached wrapped
graph key is unavailable. `Core.fail During_local_restore` correctly sets
`sync_phase = Failed`, `startup.failure = Some During_local_restore`, and
`last_error`. A subsequent successful authentication for the same account erases
both error fields in `authenticate` and `request_catalog_reconciliation`.
`catalog_refreshed` clears them again when the selected graph remains authorized.
These transitions do not restart local key loading or graph attachment.

The resulting state is authenticated with a selected graph, `sync_phase = Failed`,
`restoring_local = true`, and no failure or diagnostic message. The graph remains
closed. `Journal_startup.derive` falls through to `Restoring_local`, and the startup
UI displays `Restoring your graph` without the existing online recovery action.

This was observed in the macOS Debug app after deleting the local graph copy and
relaunching. The error-erasure defect was also reproduced independently using only
`Core.step`, a synthetic cached encrypted graph, and explicit effect completions:

| Event | Sync phase | Startup failure | Last error |
| --- | --- | --- | --- |
| Cached-key load fails | Failed | During_local_restore | wrappedGraphKeyUnavailable |
| Same-account authentication succeeds | Failed | None | None |
| Catalog refresh succeeds | Failed | None | None |

The initiating reset lifecycle defect is tracked separately in
[Complete Delete And Redownload Lifecycle](../../exploring/bugfix/2026-09-05-complete-delete-and-redownload-lifecycle.md).
This decision covers only failure preservation during reconciliation. Its test
must reproduce a missing key directly; executing reset is unnecessary.

## Proposal

Preserve an existing `During_local_restore` failure and its diagnostic message
when the same account authenticates and when catalog reconciliation succeeds
with the selected graph still present. Authentication and catalog success confirm
the account and authorization facts; they do not establish that local restoration
succeeded. Continue updating those facts and refreshing the catalog while retaining
the local failure, selected graph, and failed sync state.

Review the unconditional error clearing in `authenticate`,
`request_catalog_reconciliation`, and the selected-graph branch of
`catalog_refreshed` in `logseq_sync/lib/pure_reducer/core.ml`. Make the minimal
change needed to preserve this failure through all three paths. Keep existing
account replacement, sign-out, graph removal, and successful recovery transitions
responsible for invalidating or resolving their own state. Do not preserve a
failure across an unrelated account or graph lifecycle.

The existing `Online_recovery_requested` transition remains the explicit recovery
entry point. Same-account authentication and catalog refresh must not silently
start E2EE recovery, clear the local failure, or mark the graph ready. Keeping the
failure intact allows the existing startup derivation to display the recovery
surface. No UI change is proposed; retain the most recently selected graph as
required by `docs/ux-guidelines.md`.

### Single regression testcase

Add exactly one new pure_reducer testcase in its own file:

`logseq_sync/test/local_restore_failure_reconciliation.ml`

Keep the scenario and its small fixture helpers in that file. Export one
`Alcotest.test_case` value and register it once in the existing `pure core` group
in `logseq_sync/test/test_sync.ml`. Do not add additional cases, parameterized
variants, an integration test, or an Application/Flutter test for this decision.
Do not refactor or move existing test scenarios.

Place an English OCaml comment immediately above the scenario function, explaining
the event ordering and the regression it protects against. For example:

```ocaml
(* A warm restore can fail before same-account authentication completes.
   Authentication and catalog success must preserve the local restore failure:
   neither event retries key loading or opens the graph. Clearing the failure
   leaves startup waiting indefinitely and removes the explicit recovery action. *)
```

Use the public pure_reducer API to execute one deterministic scenario:

1. Create an initial Core with a synthetic account and encrypted graph.
2. Send `Restore_local_account`. Complete its emitted `Load_catalog` ticket with
   a cache containing that graph as the selected graph.
3. Send `Mirror_inspected (Mirror_available ...)` using the admitted graph scope.
4. Complete the emitted `Load_and_unlock_graph_key` ticket with
   `Error (Effect_failed "wrappedGraphKeyUnavailable")`.
5. Verify the local-restore failure, message, selected graph, and failed sync state.
6. Send `Account_authenticated` for the same account. Verify that authentication
   succeeds and catalog reconciliation is requested while the same local failure
   and message remain present.
7. Complete the emitted `Fetch_catalog` ticket successfully with the selected graph
   still present. Verify that catalog loading finishes and the failure and message
   remain present, with the same graph selected and `sync_phase = Failed`.
8. Verify that reconciliation did not emit mirror inspection, key loading, graph
   attachment, or E2EE/bootstrap recovery effects. Then send the explicit
   `Online_recovery_requested` event and verify that it emits the existing E2EE
   recovery request and clears the local failure through that recovery transition.

Capture tickets from the actual emitted instructions. Observe state through
`Core.state`; do not construct private Core records, call an effect runner, access
Keychain or SQLite, use real credentials, or depend on timers, network, or UI.
The test proves failure preservation and the availability of the explicit reducer
recovery transition. UI text is an implication of the existing startup derivation,
not an assertion made by this pure_reducer testcase.

Write the testcase before the production change and run it against the current
implementation. It must fail because same-account authentication clears the local
failure. After the fix, the same single testcase must pass through authentication,
catalog completion, and explicit recovery. The temporary investigative script
asserts the buggy result; the committed regression must assert the intended result.

### File boundaries

Expected implementation files are `logseq_sync/lib/pure_reducer/core.ml`, the new
test module, and the existing test registration file. The explicit `(modules ...)`
list in `logseq_sync/test/dune` also needs the new module name for normal suite
execution. On 2026-09-06, the user explicitly authorized adding only
`local_restore_failure_reconciliation` to that module list. This satisfies the
`AGENTS.md` authorization requirement for this specific edit; other Dune changes
remain outside the authorized scope.

Do not modify OCaml files under `spec/`, any bonsai_flutter repository OCaml file,
the reset lifecycle implementation, or UI code. No compatibility layer, fallback,
or migration is introduced.

## Decision

Preserve `During_local_restore` and its diagnostic together through same-account
authentication, catalog reconciliation setup, and successful catalog completion
for the selected graph. These paths share `clear_reconciliation_failure`, which
retains this local failure and keeps the existing clearing behavior for other
failure stages. Account replacement, sign-out, graph removal, and explicit
recovery retain their existing lifecycle handling.

## Alternatives considered

### Infer failure from the sync phase in Application

Treat every failed sync phase as a startup failure. This cannot recover the erased
owner and diagnostic, and sync failure can also occur after a graph opens. Preserve
the local failure at its source instead of inventing recovery information in UI.

### Retry graph opening automatically after authentication

Retrying with the same missing key does not repair local state. Starting online
E2EE recovery automatically also changes the existing explicit recovery behavior.
Neither is needed to prevent reconciliation from erasing the failure.

### Preserve all errors unconditionally

This would retain obsolete failures after account changes, graph removal, or
successful recovery. Limit this change to the existing local-restore failure for
the same selected graph and account.

## Acceptance criteria

- Exactly one new pure_reducer testcase is added, in the independent `.ml` file
  specified above, with an English comment explaining the regression.
- The testcase fails on the existing implementation and passes after the fix.
- Same-account authentication and successful catalog refresh retain
  `Some During_local_restore`, the original diagnostic message, the selected graph,
  and `sync_phase = Failed` while still completing catalog reconciliation.
- Reconciliation does not implicitly restart graph opening or E2EE recovery.
- The explicit recovery event still initiates the existing recovery transition.
- The focused testcase and existing pure_reducer tests pass. Document validation
  and formatting checks pass for the changed files.
- The first reset lifecycle problem remains outside this change. No spec, framework,
  compatibility, or UI changes are introduced. The only authorized Dune change is
  adding the new test module to `logseq_sync/test/dune`.

## Risks

- Preserving only one of `startup.failure` and `last_error` would leave inconsistent
  diagnostics or recovery behavior. Preserve them together for the local failure.
- Authentication request setup and catalog completion both currently clear errors.
  Correcting only one path would leave the later transition able to erase the failure.
- A broad preservation rule could carry obsolete failures into another account or
  graph. Keep existing lifecycle invalidation behavior intact.
- This change restores actionable failure reporting; it does not repair the separate
  delete-and-redownload lifecycle defect.

## Consequences

Successful authentication and authorization reconciliation no longer hide a
failed local restore. The graph stays selected with failed sync state until an
existing recovery or lifecycle transition handles it. Reconciliation still
refreshes and saves the catalog without opening the graph or starting online
recovery. The existing startup derivation can therefore retain its recovery
surface without a UI change.

The separate delete-and-redownload lifecycle defect remains unresolved by this
decision.

## Implementation outcome

Implemented on 2026-09-06.

- Added exactly one testcase in
  `logseq_sync/test/local_restore_failure_reconciliation.ml`, registered once in
  the existing `pure core` group. The only Dune edit adds that module name.
- Before the production change, the focused testcase failed at
  `same-account authentication: local restore failure`; the initial missing-key
  failure and diagnostic assertions passed.
- After the change, the same testcase passes through authentication, successful
  catalog completion, and explicit online recovery. It verifies the original
  diagnostic, selected graph, failed sync state, catalog progress, and absence of
  implicit graph-opening or recovery instructions.
- The focused testcase, all 34 `pure core` tests, `dune build @all`, and the full
  `dune runtest` suite pass. The sync suite contains 118 passing tests.
- Changed-file `ocamlformat --check`, Dune formatting validation,
  `git diff --check`, and `spec-dev-tool check --all` pass.
- No spec, framework, reset lifecycle, or UI implementation was changed.

## Questions

- None. The user approved the narrowly scoped Dune registration edit on 2026-09-06.
