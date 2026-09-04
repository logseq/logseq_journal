# Restore Pure Reducer Happy Path And Bad Case Tests Implementation Plan

Goal: Restore one causal pure-reducer happy-path contract and the ten ownership bad cases against the current typed overlay boundary.

Architecture: Keep the obsolete standalone bad-case paths deleted and place the rewritten cases in `logseq_sync/test/core_contract.ml` beside the current public reducer contract tests.
Every asynchronous completion must be derived from a previously asserted instruction, and every negative case must prove immutable origin, deterministic replay, no effect from an invalid event, and continued acceptance of the exact current owner.

Tech Stack: OCaml 5.1, Alcotest, Dune, `Logseq_sync_pure_reducer.Core`, `Logseq_sync_pure_reducer.Sync_protocol`, and `Logseq_overlay_db.Types`.

Related: Builds on [Rewrite Exact Pure Reducer Happy Path Cases](../../implemented/testing/2026-08-30-rewrite-exact-pure-reducer-happy-path-cases.md), [Pure Reducer Bad Case Tests](../../implemented/testing/2026-08-31-pure-reducer-bad-case-tests.md), [Enforce Pure Reducer Event Ownership](../../implemented/bugfix/2026-08-31-enforce-pure-reducer-event-ownership.md), and [Logseq Overlay DB Package Implementation Plan](../../implemented/architecture/2026-09-01-logseq-overlay-db-package.md).

## Problem

The overlay cutover removed the old Sync-owned database, outbox record, local batch, and authoritative inspection APIs.

The current worktree correctly deletes the ten old `logseq_sync/test/test_pure_reducer_bad_case_*.ml` files because their fixtures construct those obsolete values.

The current worktree also removes their Dune stanzas and makes `test/source_boundary_test.ml` reject the obsolete paths.

However, the behavioral contracts represented by those files were not restored against the new reducer API.

The former `test_pure_reducer_canonical_happy_path` was also removed when `logseq_sync/test/core_contract.ml` was rewritten.

The current suite contains focused startup, rejection, and transport tests, but it does not contain one complete causal trace from authentication through authoritative incorporation of a submitted local mutation.

Several current fixtures manufacture private ownership by injecting completions directly.

In particular, `submitted_core` injects `Graph_attached` without consuming an emitted `Attach_graph`, then injects `Outbox_transition_applied` without consuming an emitted `Apply_outbox_transition`.

Those shortcuts prevent the test suite from distinguishing a valid completion from an unsolicited callback.

The documentation examples in `logseq_overlay_db/spec/database.mli` explain the data-plane sequence below.

```text
inspect sync token
        |
        v
begin -> optional crypto -> finish -> commit
```

They do not test the reducer's orchestration sequence below.

```text
current reducer owner
        |
        v
emit instruction -> receive exact completion -> consume owner once
        |                                      |
        `------------ reject stale ------------'
```

The missing coverage matters because the current public event constructors still include `Snapshot_download_progress`, `Mirror_inspected`, `Graph_attached`, `Sync_inspected`, `Outbox_transition_applied`, `Authoritative_batch_applied`, `Websocket_opened`, `Websocket_message`, and typed runner completions.

Moving durable data ownership into `logseq_overlay_db` does not remove Sync's responsibility to correlate those events with the current account, graph, connection, request, and transition.

## Testing Plan

Add one sequential Alcotest case named `pure reducer canonical overlay happy path` to `logseq_sync/test/core_contract.ml`.

The case will traverse the current public reducer API and will derive every token, runner ticket, graph scope, connection scope, worker request, and completion payload from the exact instruction emitted by the preceding checked step.

Add ten focused Alcotest cases named `BC01` through `BC10` to the same file.

Each bad case will construct a valid origin through public events, inject one stale, duplicate, unsolicited, or mismatched event, and compare the exact public state and ordered instruction list.

Each bad case will call `Core.step` again with the same immutable origin and event to prove deterministic replay.

Each bad case will compare the origin's public observation before and after both calls to prove that `Core.step` did not mutate its input.

Each bad case that rejects a stale or mismatched completion will then deliver the exact current completion and prove that ownership was retained rather than accidentally consumed.

Run each new case immediately after writing it and before changing reducer behavior.

Record every unexpected failure as a reducer ownership defect instead of copying the implementation result into the expected value.

Implementation must follow `@Test-Driven Development (TDD)` and preserve the observed RED result before making the minimum production change.

NOTE: I will write *all* tests before I add any implementation behavior.

## Proposal

### Keep the old paths deleted

Do not restore any of the following files.

```text
logseq_sync/test/test_pure_reducer_bad_case_01_unowned_snapshot_progress.ml
logseq_sync/test/test_pure_reducer_bad_case_02_duplicate_mirror_inspection.ml
logseq_sync/test/test_pure_reducer_bad_case_03_duplicate_graph_attachment.ml
logseq_sync/test/test_pure_reducer_bad_case_04_duplicate_websocket_open.ml
logseq_sync/test/test_pure_reducer_bad_case_05_message_after_websocket_close.ml
logseq_sync/test/test_pure_reducer_bad_case_06_unsolicited_authoritative_apply.ml
logseq_sync/test/test_pure_reducer_bad_case_07_restore_accepts_old_catalog.ml
logseq_sync/test/test_pure_reducer_bad_case_08_reused_graph_token_challenge.ml
logseq_sync/test/test_pure_reducer_bad_case_09_unsolicited_local_commit.ml
logseq_sync/test/test_pure_reducer_bad_case_10_mismatched_outbox_commit.ml
```

Do not restore the removed multi-executable stanza in `logseq_sync/test/dune`.

Do not weaken the forbidden-path assertions in `test/source_boundary_test.ml`.

The tests are being restored as behavioral contracts, not as compatibility copies of obsolete source files.

### Add one public observation and assertion vocabulary

Add test-local helpers to `logseq_sync/test/core_contract.ml`.

The helpers must use only the public `Logseq_sync_pure_reducer.Core` API.

Represent the complete public observation as follows.

```ocaml
type observed =
  { state : Core.state
  ; admitted_graph_scope : Core.graph_scope option
  }
```

Add a helper that captures `Core.state` and `Core.admitted_graph_scope` before and after a transition.

Add a helper that compares exact ordered `Core.instruction list` values with `Core.equal_instructions`.

Add a helper that reports the `HPxx` or `BCxx` identifier when state or instruction equality fails.

Add a helper that applies the same event twice to the same origin and proves replay equality.

Do not compare abstract `Core.t` values directly.

Do not expose private reducer fields for tests.

Do not extract a ticket or request from an instruction until the complete expected instruction shape for that step has been checked.

### Replace causally invalid fixtures

Rewrite `submitted_core` so it no longer injects `Graph_attached` or `Outbox_transition_applied` without an owner.

Build its graph attachment by consuming the exact `Attach_graph` instruction emitted after `Mirror_inspected`.

Build its queued outbox state by delivering `Local_outbox_changed`, consuming the exact `Inspect_sync` instruction, returning a matching `Sync_inspected`, consuming the exact `Apply_outbox_transition`, and returning a matching `Outbox_transition_applied`.

Return the exact connection, submission batch, submission owner inputs, and current reducer state needed by the focused rejection tests.

Audit every existing helper in `logseq_sync/test/core_contract.ml` for the same pattern.

Replace any direct asynchronous completion with a causally extracted completion before using that helper in a restored test.

### Restore the canonical overlay happy path

Add one sequential trace with the following seventeen required checkpoints.

The shorter trace is intentional because the current overlay boundary removed the separate Sync-owned authoritative inspection and local-batch planning phases from the reducer.

| ID | Origin and event | Required result |
| --- | --- | --- |
| `HP01` | Initial state plus `Account_authenticated`. | Enter catalog discovery and publish exactly one catalog token request. |
| `HP02` | Catalog token pending plus its exact `Token_provided`. | Consume the token once and emit one typed `Fetch_catalog` request. |
| `HP03` | Catalog fetch pending plus its exact successful `Runner_completed`. | Install the catalog, publish awaiting selection, and emit the expected catalog persistence request. |
| `HP04` | Awaiting selection plus `Graph_selected`. | Admit one graph scope, emit `Inspect_mirror`, publish selected state, and persist selection in order. |
| `HP05` | Mirror inspection pending plus matching `Mirror_available`. | Emit exactly one `Attach_graph` for the inspected graph scope. |
| `HP06` | Attachment pending plus matching `Graph_attached` carrying an empty `sync_view` at cursor zero. | Consume the attachment owner, publish the attached state, and request a WebSocket token. |
| `HP07` | WebSocket token pending plus its exact `Token_provided`. | Consume the token and emit one `Start_websocket` with the next connection generation. |
| `HP08` | WebSocket start pending plus matching `Websocket_opened`. | Mark the connection live, publish `Pulling`, and send one `Pull` from cursor zero. |
| `HP09` | Opening pull pending plus a matching `Pull_ok` containing one remote transaction at cursor one. | Retain the authoritative owner and emit exactly one `Apply_authoritative_batch`. |
| `HP10` | Authoritative apply pending plus matching `Authoritative_batch_applied`. | Consume the authoritative owner, advance the checkpoint to one, publish `Current`, and retain the returned `sync_view`. |
| `HP11` | Current graph plus `Local_outbox_changed`. | Emit exactly one `Inspect_sync` for the admitted graph without changing public state. |
| `HP12` | Sync inspection pending plus matching `Sync_inspected` containing one eligible queued mutation. | Enter `Submitting`, publish state, and emit one `Apply_outbox_transition` with `Submit_group`. |
| `HP13` | Outbox transition pending plus matching `Outbox_transition_applied` carrying one `submission_batch`. | Consume the transition owner, retain the submission owner, and send exactly one `Tx_batch`. |
| `HP14` | Submission owner active plus matching `Tx_batch_ok`. | Retain the submission owner and emit one `Apply_outbox_transition` with the exact `Accept_group`. |
| `HP15` | Acceptance transition pending plus matching `Outbox_transition_applied` without a new submission batch. | Enter `Pulling`, publish state, and send one confirmation `Pull` from cursor one. |
| `HP16` | Confirmation pull pending plus matching `Pull_ok` containing the incorporated transaction at cursor two. | Retain the confirmation owner and emit exactly one `Apply_authoritative_batch`. |
| `HP17` | Confirmation apply pending plus matching `Authoritative_batch_applied` clearing the transport owner. | Advance to cursor two, release the submission owner, publish `Current`, and emit no duplicate submission. |

Every checkpoint must assert the exact public observation and complete ordered instruction list before the next checkpoint is constructed.

Every checkpoint must be replayed from its immutable origin.

Opaque overlay tokens, cursors, checksums, mutation fingerprints, and batch IDs must be created through their public validating constructors.

The trace must not use Datascript values, raw outbox records, raw transaction operations, or implementation modules.

### Restore BC01 through BC10 against current events

Use the following current-API mapping.

| ID | Invalid event | Required rejection and retained-owner probe |
| --- | --- | --- |
| `BC01` | `Snapshot_download_progress` when no snapshot download is active. | Preserve the exact initial observation, publish nothing, then prove a later valid startup event remains usable. |
| `BC02` | Replay `Mirror_inspected` after its matching inspection has already produced and completed `Attach_graph`. | Emit no second `Attach_graph`, preserve the attached state, and keep the current graph usable. |
| `BC03` | Replay `Graph_attached` after attachment has completed and the WebSocket connection is live. | Emit no new token request, preserve the live connection, and allow its next legitimate server event. |
| `BC04` | Replay `Websocket_opened` for an already live current connection. | Emit no second pull, preserve the live connection, and allow the next legitimate server message. |
| `BC05` | Deliver `Websocket_message` after the same connection has closed. | Emit no failure or worker instruction, preserve the closed state, and allow a later fresh connection generation. |
| `BC06` | Deliver `Authoritative_batch_applied` with no active authoritative batch. | Preserve state, emit nothing, then prove a subsequently requested authoritative completion is accepted. |
| `BC07` | Complete an old account's `Fetch_catalog` after `Restore_local_account` has started a new account generation. | Keep the new restoration state and catalog, emit nothing, then accept the new account's exact load completion. |
| `BC08` | Replay a rejected old WebSocket token after a recovery path has issued a fresh token request. | Keep the old token rejected, accept the fresh token exactly once, and prove their opaque IDs differ. |
| `BC09` | Deliver `Sync_inspected` containing queued work without a currently pending `Inspect_sync`. | Emit no submission transition, preserve state, then accept the result of a newly emitted exact `Inspect_sync`. |
| `BC10` | Deliver `Outbox_transition_applied` whose scope or committed transition differs from the currently pending `Apply_outbox_transition`. | Emit no WebSocket transaction, retain the pending transition owner, then accept the exact completion once. |

The old `BC09` event named `Local_batch_committed` no longer exists.

Its invariant is now owned by the `Local_outbox_changed` to `Inspect_sync` to `Sync_inspected` boundary.

The old `BC10` event named `Outbox_transition_committed` is replaced by the typed `Outbox_transition_applied` result.

For `BC06`, build the valid follow-up authoritative completion from an emitted `Apply_authoritative_batch` and return a matching `authoritative_commit` and `sync_view`.

For `BC10`, mismatch exactly one semantic field at a time so the failure identifies correlation rather than malformed fixture construction.

### Preserve the lower data-plane test boundary

Do not duplicate overlay database behavior in the reducer suite.

Keep cursor continuity, encrypted value correlation, outbox admission, durable atomicity, authoritative rebase, terminal receipt, and stale sync-token behavior in `logseq_overlay_db/test`.

Use overlay DTO constructors in reducer fixtures only to express worker results that the reducer must orchestrate.

The reducer tests must assert whether a result is owned and what instruction follows, not recompute the overlay result.

### Apply minimum ownership fixes only after RED

If the restored tests fail, preserve the failing output before changing `logseq_sync/lib/pure_reducer/core.ml`.

The implementation is authorized to make the minimum private ownership fixes needed to satisfy a restored normative test after that RED result has been preserved.

`Sync_inspected` is valid only while an `Inspect_sync` is pending for the current graph scope.

Because the public event carries no request identifier, the reducer must permit at most one pending sync inspection per graph scope, correlate the completion by that scope, and consume the pending owner exactly once.

An unsolicited `Sync_inspected`, including an administrative refresh for the current scope, is ignored.

Prefer concrete private pending owners over booleans.

The expected minimum private ownership model is shown below.

```text
Inspect_mirror request --------> pending mirror inspection scope
Attach_graph request ----------> pending attachment scope
Inspect_sync request ----------> pending sync inspection scope
Apply_outbox_transition -------> pending exact transition request
Apply_authoritative_batch -----> active authoritative batch
Download_snapshot request -----> active snapshot download scope
```

Consume each owner exactly once on the matching completion.

Reject a completion whose scope, generation, transition, or active phase does not match.

Clear all affected owners on account replacement, graph replacement, graph picker return, foreground connection replacement where applicable, failure, and shutdown.

Do not add public owner tokens merely to make tests convenient.

Do not reintroduce raw database or outbox ownership into Sync.

Do not modify `logseq_sync/spec/pure_reducer/core.mli` unless implementation reveals that the current public completion payload cannot express a semantically valid correlation.

If the public `.mli` proves insufficient, stop and report the exact missing identity before editing it, as required by the repository instructions.

## Implementation Plan

### Task 1: Establish the current baseline

1. Run `dune exec logseq_sync/test/test_sync.exe -- test '^pure core$'`.
2. Confirm that the current fifteen pure-core cases pass before adding restored coverage.
3. Run `git status --short -- logseq_sync/test logseq_sync/lib/pure_reducer test/source_boundary_test.ml`.
4. Record pre-existing worktree changes and avoid overwriting them.
5. Confirm that the ten obsolete bad-case files remain absent.

### Task 2: Add causal assertion helpers

1. Add the public `observed` view to `logseq_sync/test/core_contract.ml`.
2. Add exact observation comparison with an explicit test ID.
3. Add exact ordered-instruction comparison with an explicit test ID.
4. Add immutable-origin comparison around `Core.step`.
5. Add deterministic replay comparison from the same origin.
6. Run `ocamlformat --check logseq_sync/test/core_contract.ml`.
7. Run the pure-core test executable and confirm the existing cases remain green.

### Task 3: Replace invalid setup shortcuts

1. Rewrite the attachment portion of `submitted_core` from emitted `Inspect_mirror` and `Attach_graph` instructions.
2. Run the focused cases using `submitted_core` and observe any correlation failure.
3. Rewrite the submission portion from emitted `Inspect_sync` and `Apply_outbox_transition` instructions.
4. Run the focused rejection cases and confirm their existing behavioral assertions remain green.
5. Audit the other setup helpers for directly injected asynchronous completions.
6. Replace each invalid shortcut with a causally extracted payload.
7. Run the complete current pure-core suite.

### Task 4: Write the canonical happy path before production changes

1. Add static fixture values for one graph, one remote transaction, one queued mutation, one submission batch, and two authoritative commits.
2. Add `HP01` through `HP05` and assert each step before extracting its instruction.
3. Run the happy path and preserve the first RED result.
4. Add `HP06` through `HP10` and repeat the targeted run.
5. Add `HP11` through `HP13` and repeat the targeted run.
6. Add `HP14` through `HP17` and repeat the targeted run.
7. Confirm that every step checks immutable origin and deterministic replay.
8. Do not change production behavior during this task.

### Task 5: Write BC01 through BC05 before production changes

1. Add `BC01` with an ownerless snapshot progress event.
2. Run `BC01` and preserve its RED or GREEN result.
3. Add `BC02` with a consumed mirror inspection.
4. Run `BC02` and preserve its result.
5. Add `BC03` with a consumed graph attachment.
6. Run `BC03` and preserve its result.
7. Add `BC04` with a duplicate WebSocket open.
8. Run `BC04` and preserve its result.
9. Add `BC05` with a message after WebSocket close.
10. Run `BC05` and preserve its result.
11. Do not change production behavior during this task.

### Task 6: Write BC06 through BC10 before production changes

1. Add `BC06` with an unsolicited authoritative completion and exact follow-up completion.
2. Run `BC06` and preserve its result.
3. Add `BC07` with a stale catalog completion crossing account generations.
4. Run `BC07` and preserve its result.
5. Add `BC08` with old and replacement WebSocket token challenges.
6. Run `BC08` and preserve its result.
7. Add `BC09` with an unsolicited sync inspection and exact follow-up inspection.
8. Run `BC09` and preserve its result.
9. Add `BC10` with a mismatched outbox transition result and exact follow-up result.
10. Run `BC10` and preserve its result.
11. Do not change production behavior during this task.

### Task 7: Make the restored tests green

1. Classify every RED result as an invalid expectation, invalid fixture, or reducer ownership defect.
2. Correct invalid fixtures without weakening the intended ownership assertion.
3. Keep static expectations unchanged when they represent the confirmed protocol contract.
4. Add the minimum private pending mirror-inspection owner required by `BC02` if needed.
5. Run `BC02` and the canonical trace.
6. Add the minimum private pending attachment owner required by `BC03` if needed.
7. Run `BC03` and the canonical trace.
8. Add the minimum active snapshot-download owner required by `BC01` if needed.
9. Run `BC01` and snapshot bootstrap cases.
10. Add the minimum private pending sync-inspection owner required by `BC09` if needed.
11. Run `BC09`, submission cases, and online recovery cases.
12. Replace a boolean outbox-transition marker with the exact pending request if `BC10` requires it.
13. Run `BC10`, acceptance, rejection, and deferred-authoritative cases.
14. Make no change for an already-correct bad case.
15. Run all eleven restored cases together.

### Task 8: Complete the suite and boundary checks

1. Register the canonical case and `BC01` through `BC10` in `Core_contract.scenarios`.
2. Confirm that `Core_contract.scenarios` contains the existing focused cases plus exactly eleven restored cases.
3. Run `dune exec logseq_sync/test/test_sync.exe -- test '^pure core$'`.
4. Run `dune runtest logseq_sync/test`.
5. Run `dune runtest logseq_overlay_db/test`.
6. Run `dune build @all`.
7. Run `dune build @fmt`.
8. Run `git diff --check`.
9. Run `spec-dev-tool check --all`.
10. Confirm that `test/source_boundary_test.ml` still rejects the obsolete standalone test paths.
11. Review the final diff for unrelated changes and generated fixtures.

## Decision

Keep the obsolete standalone bad-case paths deleted and restore their behavioral
contracts inside `logseq_sync/test/core_contract.ml` alongside one causal
seventeen-checkpoint overlay happy path.

Use public observations and exact ordered instructions to prove transition
results, origin immutability, and deterministic replay. Derive every valid
asynchronous completion from a previously asserted instruction.

Represent private reducer ownership with concrete pending mirror inspection,
graph attachment, snapshot download, sync inspection, and exact outbox
transition values. Consume matching owners once, reject unsolicited or
mismatched completions without consuming the current owner, clear affected
owners at lifecycle boundaries, and advance the private WebSocket connection
generation for every replacement connection request.

## Alternatives considered

### Restore the old standalone files unchanged

This would reintroduce Datascript databases, raw transaction operations, old outbox records, and removed event constructors into tests.

It would either fail to compile or require compatibility APIs forbidden by the repository rules.

### Create ten new standalone executables

This would preserve one-file-per-case isolation, but it would add Dune maintenance and duplicate a large causal setup across eleven executables.

The current `core_contract.ml` already owns the public pure-reducer contract and can share one reviewed causal fixture vocabulary.

### Treat overlay tests as replacements

Overlay tests validate durable data-plane behavior and compare-and-set tokens.

They cannot prove that the Sync reducer rejects a callback belonging to the wrong account, graph, connection, request, or transition.

### Keep only the current focused reducer tests

The current tests cover selected startup and transport branches.

They do not form a complete submission and incorporation trace, and several construct intermediate states through ownerless completion injection.

### Add public ownership fields for direct assertions

This would make private orchestration bookkeeping part of the supported API.

The tests can prove ownership by delivering matching and mismatching public events, so no new observer is justified.

## Acceptance criteria

- `logseq_sync/test/core_contract.ml` contains one canonical seventeen-step overlay happy path.
- The canonical path covers authentication, catalog loading, mirror attachment, WebSocket opening, authoritative pull, sync inspection, submission, acknowledgement, confirmation pull, and authoritative incorporation.
- `logseq_sync/test/core_contract.ml` contains current-API rewrites of `BC01` through `BC10`.
- Every restored case uses only modules exposed through the public test libraries.
- Every asynchronous completion is derived from a previously emitted and fully asserted instruction.
- No restored fixture injects `Graph_attached`, `Sync_inspected`, `Outbox_transition_applied`, or `Authoritative_batch_applied` without first obtaining its corresponding instruction.
- Every bad case proves exact public-state preservation and an empty ordered instruction list for the rejected event.
- Every bad case proves input immutability and deterministic replay.
- Every bad case with a pending current owner proves that a stale event does not consume that owner.
- The exact current completion is accepted once after its stale, duplicate, unsolicited, or mismatched counterpart is rejected.
- The old ten standalone file paths remain absent.
- `logseq_sync/test/dune` does not regain the obsolete multi-executable stanza.
- `test/source_boundary_test.ml` retains its forbidden-path assertions.
- No compatibility alias, legacy event, raw Datascript input, or raw outbox record is restored.
- No `logseq_sync/spec` `.mli` file changes unless a specific public correlation defect is reported and separately approved.
- The pure-core test executable passes with the existing focused cases and eleven restored cases.
- `dune runtest logseq_sync/test`, `dune runtest logseq_overlay_db/test`, `dune build @all`, `dune build @fmt`, `git diff --check`, and `spec-dev-tool check --all` pass.

## Risks

- Restored tests are expected to expose current reducer defects because snapshot progress, mirror inspection, graph attachment, sync inspection, and outbox transition completion currently have weaker private ownership checks than the old contracts required.
- Tightening completion ownership may invalidate current focused fixtures that inject completions directly.
- A sequential happy path can hide the first error behind a later extraction failure unless every step is asserted before payload extraction.
- Structural equality over opaque-looking DTO records can accidentally compare irrelevant representation details.
- Test helpers must compare only public semantic values and must not depend on private reducer records.
- A pending owner represented only by scope cannot distinguish two operations in the same scope unless the reducer guarantees at most one such operation.
- `Sync_inspected` carries no explicit request identifier, so its confirmed correlation policy depends on the reducer guaranteeing at most one pending `Inspect_sync` per current graph scope.
- Minimum reducer ownership fixes are authorized after a preserved RED result, but they may invalidate focused fixtures that inject completions without first obtaining the corresponding instruction.

## Consequences

- The default pure-core suite now contains the existing fifteen focused cases
  plus exactly eleven restored cases.
- Duplicate, stale, unsolicited, and mismatched callbacks can no longer advance
  reducer state or consume the exact current owner covered by BC01 through BC10.
- WebSocket recovery replaces the prior connection generation, so late messages
  from the closed connection remain fenced.
- Account replacement clears old runner tickets before issuing the new account's
  catalog load, preventing stale catalog installation.
- The public reducer interface, Dune layout, source-boundary assertions, and
  lower overlay data-plane test boundary remain unchanged.

## Testing Details

The canonical test exercises observable reducer behavior rather than data structures by driving real `Core.step` transitions with public events and exact typed worker results.

The bad cases exercise behavior rather than mocks by reaching valid reducer states, injecting invalid public events, and probing whether the real reducer preserved the correct owner.

Overlay DTOs are fixture inputs at the public Worker boundary and are not treated as the subject under test.

The immutable-origin and replay assertions verify purity, while the exact current follow-up probes verify one-shot ownership semantics that are otherwise private.

## Implementation Details

- Modify `logseq_sync/test/core_contract.ml` for the restored contract tests and causal helpers.
- Keep `logseq_sync/test/dune` unchanged.
- Keep `test/source_boundary_test.ml` unchanged.
- Keep all ten obsolete standalone bad-case paths deleted.
- Reuse current public overlay token and batch constructors.
- Derive completions only from asserted instructions.
- Replace invalid fixture shortcuts before using them as origins.
- Modify `logseq_sync/lib/pure_reducer/core.ml` only after a preserved RED result and only as minimally required by the restored normative test.
- Do not modify `logseq_sync/spec/pure_reducer/core.mli` without reporting a concrete specification blocker.
- Run narrow tests after every restored case and the full repository checks at completion.

## Questions

None.

The user confirmed that a preserved RED result authorizes the minimum private ownership fix in `logseq_sync/lib/pure_reducer/core.ml`.

The user confirmed that `BC09` rejects `Sync_inspected` unless an `Inspect_sync` is pending for the current graph scope; unsolicited administrative refreshes are not accepted.

## Implementation

Added the canonical `HP01` through `HP17` trace and `BC01` through `BC10` to
`logseq_sync/test/core_contract.ml`. Added test-local exact observation,
instruction, immutability, and replay helpers, and rewrote existing setup
fixtures so valid completions are causally extracted from emitted instructions.

Updated only private state and transition logic in
`logseq_sync/lib/pure_reducer/core.ml`. Added concrete pending owners for mirror
inspection, graph attachment, snapshot download, sync inspection, and outbox
transition requests; fenced old account runner tickets; consumed owners once;
and incremented replacement WebSocket connection generations.

No public `.mli`, Dune file, obsolete standalone test path, overlay data-plane
test, or source-boundary assertion was changed by this implementation.

## Verification evidence

- The pre-change baseline passed all fifteen existing pure-core cases.
- The preserved RED runs failed at the intended behavioral assertions for BC01,
  BC02, BC03, BC05, BC07, BC09, and BC10. The canonical trace and BC04, BC06,
  and BC08 were already green.
- `dune exec logseq_sync/test/test_sync.exe -- test '^pure core$'` passes all
  twenty-six pure-core cases.
- `dune runtest logseq_sync/test logseq_overlay_db/test` passes.
- `dune build @all` and `dune build @fmt` pass.
- `git diff --check` passes.
- The ten obsolete standalone files remain absent, while
  `test/source_boundary_test.ml` retains all ten forbidden-path assertions.
- `Core_contract.scenarios` contains exactly the existing fifteen focused cases
  plus the eleven restored cases.

---
