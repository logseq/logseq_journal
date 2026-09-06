# Reconcile Mutation Revisions Editor Input And Diagnostics

## Problem

This decision groups issues **3, 5, and 6** from the
[2026-09-06 macOS mutation and sync audit](../../../test-reports/2026-09-06-macos-graph-mutations-and-sync.md).
They concern mutation preconditions, controlled editor input, and admission
diagnostics. The audit reproduced all three in the macOS Debug app built from the
current worktree. A common root cause has not been established.

### Issue 3 / M03: false conflicts and repeated delete failure

A newly captured block was visible on the Logseq peer before its first status
change. Selecting Backlog failed with `Status changed elsewhere. Try again.`,
although that block had not been edited on the peer. An identical retry succeeded.

A newly captured Todo failed deletion twice. The row disappeared during the undo
window, then returned with `unsupportedSemantics`, operation `deleteSubtree`, and
`The mutation precondition did not match.` That Todo had not been edited on the
peer either. Restarting refreshed the graph and allowed the deletion to reach the
peer. The later sync acknowledgement stall is a separate audit issue, M02.

Current `app/journal_graph_runtime.ml` already forwards the caller's opaque block
revision for status mutations and uses `delete_preconditions` for subtree deletion.
Do not assume that the historical global-basis bug is still the explanation. Trace
which block and structure revisions the UI receives, retains, and submits after
capture, reconciliation, conflict handling, and undo.

### Issue 5 / M05: pasted input is lost before save

Capture accepted an ASCII prefix. Pasting multiline text with Chinese characters
and an emoji briefly changed the accessibility value, but the rendered field and
saved block retained only the prefix. With real Cmd+C in TextEdit and Cmd+V in
Capture, subsequent typing also continued from the old value and discarded the
pasted text. TextEdit retained the same pasted content.

The automation `typeText` API separately dropped non-ASCII simulated keystrokes in
both applications. That tool limitation is not evidence of an application defect.
The reproduction above concerns paste and the application's retained value.

`app/journal_capture.ml` and `app/journal_detail.ml` reject text events unless
`base_document_revision` exactly equals the current document revision. This can
reject a newer complete editing value that shares an older base revision with an
already acknowledged edit. The
[existing controlled-input investigation](../../exploring/bugfix/2026-09-05-accept-rapid-controlled-text-input-edits.md)
documents this risk; the precise event ordering of the audited paste still needs
to be established.

### Issue 6 / M06: Diagnostics remains Loading

With the graph Ready / Open, Account > Diagnostics left all four admission fields
at Loading: Outbox records, Outbox bytes, Protected payload, and Origin evidence.
Reopening the screen and restarting did not resolve it. The fields stayed Loading
both when a read-only SQLite inspection found zero outbox records and when it found
three pending records.

`Application.Admission_refresh` models request coalescing and completion. The
application's dedicated worker-response branch handles `Admission_inspected` and
`Admission_unavailable`, while generic `apply_worker_response` ignores them.
`run_admission_directive` handles delivery errors but ignores successful delivery
responses. These different completion paths are investigation targets, not yet a
proven explanation for the live Loading state.

## Proposal

Address issues 3, 5, and 6 within the scope and regression test policy below.
The user requested promotion to proposed on 2026-09-06 and subsequently requested
completion of all proposed decisions. The implementation and verification below
record that outcome.

Investigate each issue independently through the existing production state and
event boundaries. Record a deterministic failing sequence before selecting an
implementation. A fixture must not invent a stale revision or omit a completion
that the real system would have delivered merely to manufacture a failure.

### Mutation revision ownership

- Follow capture completion and subsequent authoritative changes through
  `app/journal_graph_runtime.ml`, `app/application.ml`, and
  `app/journal_timeline_state.ml`. Identify the exact point where a current block
  or structure revision stops reaching the caller-visible state.
- Preserve target-local equality preconditions and graph/request generation
  fences. Updating the UI from an authoritative result is different from silently
  substituting a newer private revision when submitting an old user action.
- When a genuine conflict is returned, restore the row, clear pending state, and
  reconcile the affected authoritative state before another action can reuse an
  obsolete revision. Preserve Undo's cancellation of the uncommitted deletion.
- Do not bypass concurrency checks, restore a global-basis comparison, or hide
  stale state with unconditional retry.

### Controlled input admission

- Reproduce consecutive full-value text edits with increasing local revisions and
  the same base document revision, including paste followed by another edit.
- Evaluate one shared admission transition for Capture and Detail: same session,
  strictly newer local revision, and no future base document revision. An ordinary
  acknowledgement must preserve the complete text, UTF-16 selection, and composing
  range. Preserve Capture's saving guard and Detail's editing-mode guard.
- Programmatic replacements that invalidate queued host edits should replace the
  session. Ordinary acknowledgements should retain it. Verify reset, reload, and
  conflict-resolution ownership rather than loosening revision checks alone.
- The existing input document remains background context. This combined decision
  owns the issue-5 regression test policy below; it does not require an additional
  parallel editor test suite.

### Admission inspection completion

- Trace Diagnostics open, request dispatch, worker completion, response delivery,
  graph changes, and screen close/reopen using the actual correlation identities.
- Determine whether completion is missing, routed through an ignored branch, or
  rejected by a generation/in-flight guard. Test the responsible production path,
  not only `Admission_refresh.complete` in isolation.
- A matching successful completion must publish the real inspection, including
  zero counts. A failed/unavailable completion or unavailable graph must terminate
  Loading explicitly. Stale completions must not replace a newer graph's result.
- Preserve coalescing: repeated triggers while a request is pending should lead to
  at most one additional inspection after completion, without leaving the previous
  request permanently in flight. Do not replace missing data with fabricated zeros
  or add polling to conceal a dropped completion.

### Required regression test policy

**If an issue can be reproduced with pure_reducer testcases, add only
pure_reducer regression tests for that issue. Put all such new cases for this
decision in one dedicated `.ml` test file.** Do not also add equivalent widget,
golden, effect-runner, integration, or E2E tests for an already reproduced case.

Proposed dedicated file:
`test/macos_mutation_input_diagnostics_pure_reducer_test.ml`. Keep the issue-specific
fixtures and testcase groups together in that file rather than appending cases to
the existing broad test suites or creating one file per issue.

For each issue:

1. Identify the production reducer or pure state transition that actually owns the
   behavior. `logseq_db_worker.pure_reducer` owns worker routing/lifecycle and
   `logseq_sync.pure_reducer` owns sync policy; neither should be made to own editor
   or application presentation state just to fit a test name. Calling a mutable
   runtime or a real runner does not become a pure_reducer test by renaming it.
2. Drive the production transition with explicit input events and typed completion
   values. Assert resulting state, emitted commands/effects, correlation, and
   rejected stale events. Do not use network services, SQLite, Keychain, Flutter
   rendering, wall-clock sleeps, or a test-only copy of the implementation.
3. Run the new testcase against the unfixed implementation and verify that it fails
   on the audited invariant. A green test of a nearby helper is not a reproduction.
4. If this reproduces the issue, keep new regression coverage exclusively in that
   pure_reducer file. After the eventual fix, the same testcase must pass without
   weakening its assertions. Existing relevant suites may still be run unchanged.
5. If the actual cause cannot be represented through a production pure boundary,
   document the specific missing boundary and evidence before choosing another test
   layer. Do not claim pure_reducer reproduction or automatically add broad suites.

| Group | Required failing sequence and assertions |
| --- | --- |
| M03: status and delete | Capture and reconcile a block, then admit its first status change; assert the observed target revision and absence of a false conflict. Separately cover capture-as-Todo, the delete deadline, failure recovery, and a second delete. Include an unrelated change, a real conflicting change, Undo before the deadline, and stale graph completions. Keep block and structure revision expectations distinct. |
| M05: input | Deliver a prefix edit, a full-value paste using the same base revision with a newer local revision, and a subsequent full-value edit. Assert full retained text, selection/composition, acknowledgement revisions, and the eventual save command's source. Reject duplicate/out-of-order local revisions, future base revisions, and replaced sessions; preserve mode guards. |
| M06: diagnostics | Open Diagnostics on an open graph, deliver the matching inspection through its production completion route, and assert Available with actual values. Cover failure/unavailable, repeated triggers, close/reopen, and a graph-generation change followed by a stale completion. Prove dispatch and completion leave no orphaned in-flight state. |

Test registration must be executable and verified in the eventual implementation;
an unregistered file is not coverage. Existing dune stanzas enumerate modules
explicitly. This document does not authorize changing any dune file: if registration
needs such a change, that remains subject to the repository's explicit-authorization
rule. Do not silently edit dune or any `spec/` OCaml file, or modify OCaml files in
the bonsai_flutter repository. If an unclear or unreasonable spec blocks development,
stop and report the exact spec issue, suggested change, and rationale.

Out of scope: the independent sync queue stall, missing Detail navigation, expanded
child display loss, local-reset lifecycle, and a general rewrite of the sync or
application architecture. Investigate an overlapping path only as needed to prove
and address M03, M05, or M06.

## Decision

Implement the independently reproduced causes through their existing owners:

- Preserve an acknowledged change-window boundary in the worker effect runner.
  Start real windows after the empty-read cursor; reject unknown cursors with a
  resync response without discarding retained changes. This repairs the revision
  delivery path that caused M03's false stale preconditions.
- On a real delete conflict, read and publish the authoritative page tree, restoring
  the target before the next action. Keep caller-observed block preconditions and
  separately cached structure scopes; do not retry a rejected delete automatically.
- Preserve current timeline reconciliation while a deletion is staged. Undo inserts
  only the removed slots into the latest state. Schedule the deadline's command
  from the state transition that verifies the current pending mutation, so Undo
  cancels the command and reconciliation does not resurrect a hidden row early.
- Share Capture and Detail's full-value editor admission. Accept increasing local
  revisions from the current session with a non-future base, preserve complete
  UTF-16 editing values, and rotate sessions on actual programmatic replacement.
  Route reloads allocate from the latest editor session rather than an old seed.
- Independently fix native M05: route macOS Edit menu commands through Flutter's
  standard `PlatformMenuBar` and focused editing intents. Remove the obsolete
  AppKit Edit selectors from `MainMenu.xib`. The main Capture's Flutter-owned
  controller does not use the OCaml controlled-input transition, so its live defect
  cannot be attributed to that transition.
- Schedule admission inspections using the Bonsai state-machine action context.
  An injected state action is not a completed updater: the old reference-and-bind
  dispatch read `No_request` before the updater wrote its result. Correlate each
  inspection with both graph and request generation, retain coalescing, and settle
  matching successful, unavailable, or failed service responses explicitly.

No dune file, `spec/` OCaml file, or bonsai_flutter repository OCaml file was
modified by this decision. The application keeps its existing layout and startup
behavior, with built-in platform menus providing native editing commands.

## Alternatives considered

### Add E2E and widget tests for every issue

This duplicates coverage when the failing state/event sequence is reproducible in
pure_reducer tests and conflicts with the requested test policy. The existing macOS
audit supplies runtime evidence; new test scope should follow the demonstrated
ownership boundary.

### Assume all three issues are a single sync failure

The symptoms cross different state owners. Paste can lose text before a graph write
exists, and admission diagnostics have their own completion path. A combined
document does not justify a combined unproven root cause.

### Substitute current revisions, delay input, or poll Diagnostics

These approaches can hide the symptoms while weakening concurrency or making
correctness depend on timing. Prefer correct event admission, state reconciliation,
and completion handling. Remove obsolete paths when replacing them; do not retain
compatibility layers, fallbacks, or migrations.

### Add cases to existing shared test files

This violates the requested independent-file organization and makes it harder to
inspect the three reproductions together. Use one dedicated `.ml` file for the new
pure_reducer cases, with only necessary registration outside it when authorized.

## Acceptance criteria

- Each issue has a documented production event sequence and an identified state or
  completion owner; inferred causes are distinguished from verified causes.
- M03: a captured/reconciled target can be changed or deleted without a false stale
  precondition; a real conflict remains protected and reconciles state for the next
  action; Undo emits no delete after cancellation.
- M05: an admitted paste and following edit survive acknowledgement and appear in
  the save source exactly, including multiline Unicode, UTF-16 selection, and
  composition. Stale sessions and invalid revisions remain rejected.
- M06: matching inspection results terminate Loading with real metrics, while
  failure/unavailable and graph replacement settle the request safely. Coalesced
  requests and stale completions cannot leave Diagnostics permanently Loading.
- Every issue reproducible by pure_reducer testcases receives only pure_reducer
  regression additions, all in the one independent `.ml` test file. Record the
  failing-before and passing-after command/results for the actual testcase.
- Tests that pass without reproducing the failing ownership path do not satisfy
  these criteria. Any inability to reproduce an issue purely is explicitly recorded
  before selecting a different test boundary.
- Implementation respects spec/dune restrictions and `docs/ux-guidelines.md`.
- `spec-dev-tool check` for this document and `spec-dev-tool check --all` pass. The
  document remains proposed until the fixes and required verification are complete.

## Risks

- A stale caller revision may involve a structure scope as well as the block token.
  Fixing only the displayed status could leave subtree deletion broken.
- Accepting older-base full editing values without session replacement at a true
  programmatic reset could let a queued edit overwrite that reset.
- A pure helper test can miss discarded completions in application dispatch. A
  faithful reproduction must include the actual owner and observable output path.
- Expanding pure APIs solely for testing could introduce an unnecessary refactor.
  Do not replace production behavior with a parallel test model.
- The live sync queue failure is independent evidence and may prevent a later
  end-to-end audit from completing even after these three issues are fixed.

## Consequences

Authoritative revisions reach the next user mutation, real conflicts remain
protected, and an undoable deletion keeps reconciled data without losing its
cancellation guarantee. Controlled editor acknowledgements retain complete input;
native macOS paste now reaches the controller that supplies Capture's save text.
Diagnostics dispatches inspections and displays real values rather than orphaning
Loading state.

New pure regression additions are confined to
`test/macos_mutation_input_diagnostics_pure_reducer_test.ml`. Distinct non-pure
causes have narrow runtime, application-dispatch, and native-menu coverage. The
standalone OCaml entry point is run separately from `dune runtest`, because dune
registration changes were not authorized.

The independent M02 submitted-delete recovery defect remains outside this
decision. Its two intentionally failing public Core reproductions remain intact,
as required by the implemented submitted-delete testing decision. Consequently,
full `dune runtest` still reports those two known failures; this decision does not
claim an entirely green repository or successful peer synchronization of the new
native QA marker.

## Questions

None. The user authorized completion of the proposed decisions.

## Ownership and verification

The following placement decisions were recorded during investigation before
selecting the corresponding non-pure coverage:

| Cause and production owner | Failing-before evidence | Passing-after coverage |
| --- | --- | --- |
| M03 retained windows in the mutable worker effect runner | Acknowledging a cursor swallowed the next real window; an empty-read boundary also swallowed the first real change | Real public worker operations and disposable SQLite fixture; four runtime cases pass |
| M03 delete-conflict routing in `Journal_graph_runtime` | A real concurrent source write followed by stale deletion never produced authoritative conflict reconciliation | Capture Todo, real conflict refresh, then successful second deletion through public runtime commands |
| M03 pure Undo and editor route ownership | Undo restored an old sibling revision; reload reused an already replaced editor session | Dedicated pure cases assert current sibling preservation and session fencing |
| M03 Bonsai deletion scheduling and pending-row reconciliation | A real application refresh resurrected the row during its Undo window | Headless production application events verify hidden row, latest text on Undo, zero cancelled commands, and exactly one later deletion |
| M05 Capture/Detail pure admission and replacement | Five initial cases failed: both same-base input pipelines and Capture replacement, Detail discard, and Detail commit fences | Shared editor transition; complete Unicode text, UTF-16 ranges, save source, invalid-event/mode guards, and replacement fences |
| M05 native AppKit menu delivery | Rebuilt app's Cmd+V changed accessibility text but not rendered text; later typing discarded the paste | Native menu channel test uses the actual ExpandableMessageComposer and its save callback; live Cmd+C/Cmd+V, follow-up typing, and saved Timeline text verified |
| M06 deferred Bonsai dispatch | Opening real headless Diagnostics sent zero inspections | Production open, completion, unavailable, service failure, reopen, and recovery path passes; restoring the old dispatch after fixing the harness reproduces zero requests again |
| M06 pure request correlation | Closing and reopening the same graph accepted the old request's result | Dedicated pure case rejects old completion while the new inspection remains Loading; existing coalescing/generation tests pass |

The runtime and native tests do not duplicate a pure-reproduced defect. Pure
transitions cannot execute mutable window retention, graph-runtime refresh I/O,
Bonsai action scheduling, or macOS menu delivery. They use those production owners
rather than fabricating stale revisions or claiming a helper proves an external
failure.

### Executable commands and results

- `python3 tool/test_macos_regressions.py`: PASS, including nine named pure cases,
  four real worker/runtime cases, and the headless application dispatch/deadline
  scenario. All pure additions remain in one `.ml` file.
- `dune build @all`: PASS.
- `dune runtest`: all relevant application/worker suites pass. The sync suite has
  119 passing cases and the two pre-existing intentional M02 failures with
  `authoritative defer owner mismatch`; no new sync failure is attributed to this
  change.
- `"$(opam var bin)/bonsai-flutter" exec --profile debug -- sh -c
  'cd flutter && flutter test --no-pub'`: PASS, 56 tests, seven existing opt-in real
  runtime golden cases skipped. The native-menu regression first failed with
  `Paste must reach Flutter through the native menu` before the platform menu fix.
- `"$(opam var bin)/bonsai-flutter" build macos --profile debug`: PASS, including
  complete-object verification. The native smoke used this rebuilt application
  after restarting the old process.
- Native smoke on 2026-09-06: copy `中文 😀\nsecond line` from TextEdit; type
  `QA-M05-20260906 prefix ` in Capture; Cmd+V; append ` END`; save. The rendered
  editor and saved Timeline both retain the exact multiline source. Diagnostics
  shows Outbox `4 / 4096`, `7.2 KB / 8 MB`, protected payload `188 B`, and origin
  evidence `0 B`, with Ready / Open graph phases. The independent sync phase
  remains Submitting.
- OCaml formatting, targeted Dart analysis, `git diff --check`, and
  `spec-dev-tool check --all`: PASS.

The Python entry point loads compiled public library interfaces from
`dune ocaml top app` and the existing fixture library. It does not load production
implementation source around an interface. Each registered file must emit its
success sentinel because the OCaml toplevel can exit zero after a source error.
