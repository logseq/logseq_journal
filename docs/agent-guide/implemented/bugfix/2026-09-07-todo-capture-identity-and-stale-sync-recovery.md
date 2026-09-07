# Todo Capture Identity and Stale Sync Recovery

## Problem

Two defects reproduced in the September 7 macOS Release audit: direct Todo Capture crashes the entire UI, and the outgoing mutation queue remains stuck after restart. This document records the investigation and repair authorized by the user's implementation request. The implementation and verification record below supersede the earlier investigation-only baseline.

The detailed live observations are in the [macOS retest report](../../../test-reports/2026-09-07-lambda-rtc-test-macos-retest.md), issues L01 and L02. The other six audit findings are outside this decision.

### L01: Capture completion duplicates an existing timeline identity

- Direct Todo Capture produced `BonsaiRuntimeException(fatalError, duplicateKey)` within 1,410 ms. The same block key appeared twice under `journal-timeline-list`.
- Capture inserts a plain block, then performs a separate task-status mutation. Incoming graph changes can reconcile the page before the Capture completion arrives.
- `app/application.ml` handles `Block_captured` by calling `Journal_timeline_state.prepend_timeline_entry`. The function in `app/journal_timeline_state.ml` always inserts and increments `total_count`; it does not check the block UUID. If reconciliation has already installed that block, completion creates a second slot with the same key.
- The state owner is `Journal_timeline_state`, rather than the Flutter renderer. A deterministic probe through its public interface loaded a feed containing one Todo entry and then supplied that same entry to `prepend_timeline_entry`. `retained_slots` returned two identical `block:00000001-0000-4000-8000-000000000901` keys: `count=2 unique=1`.
- This establishes the duplicate-identity defect without injecting an invalid renderer result. The live packet trace does not establish every event's exact ordering, but the production Capture and reconciliation paths permit the reproduced state transition.

### L02: Generic Stale rejection enters a delete-only state that cannot settle

- After restart, the UI became readable, but an `insertBlocks` record remained in `deleteBarrierRejectedPendingAuthoritative`, through cursor 33, with observed origin cursor 33. Its `setTaskStatus` and a subsequent delete stayed queued. The queue was still stuck when the local checkpoint reached 43.
- `logseq_overlay_db/lib/database.ml` maps every `Reject_plan (_, Stale { through })` to `Delete_barrier_rejected_pending_authoritative`, regardless of mutation kind. It does not settle the rejection immediately when the local checkpoint has already reached the barrier.
- `classify_stale_deletes` only understands `Delete_blocks`. If an authoritative batch reaches the rejection boundary for a non-delete record, it returns `stale delete state contains a non-delete mutation`. If the boundary was already passed, subsequent batches do not supply the exact boundary root, leaving the record pending.
- `Retry_group` looks up submitted or accepted records through `batch_records`; that lookup excludes this barrier state and returns `retry batch is missing`.
- `logseq_sync/lib/pure_reducer/core.ml` treats a pending barrier as a reason to keep pulling and withhold subsequent queued submissions. Restart restores the persisted state, so it does not release the queue.
- The defective transition belongs to the Overlay Database public state machine. A deterministic probe used public local commit, submission, rejection, and authoritative-apply interfaces with a disposable seeded database. A submitted insert rejected as Stale at a future barrier reproduced the non-delete classification error. Applying an unrelated authoritative transaction before the rejection reproduced the already-reached barrier state. Both cases reproduced the Retry lookup error.
- The backup's observed own origin is evidence that the real insertion executed. Recovery must validate that evidence using existing batch identity, submission cursor, and ordinal rules. The initial acknowledgment interruption was not captured, so its exact cause remains unproven.

### Investigation baseline

The existing timeline test executable and all 11 `sync recovery reproductions` cases passed during investigation. They therefore do not demonstrate coverage of these failures. No production code or graph data was modified by the root-cause probes. The earlier user-approved local reset and redownload restored the audit graph, but did not repair either production defect.

## Decision

### Make Capture insertion idempotent by block UUID

Change the timeline state owner so an existing top-level UUID is updated in place without adding a slot or increasing `total_count`. Insert an absent UUID in the existing order. Preserve expanded child slots, pagination state, and Capture's `Reset_to_top` behavior. Both reconciliation-before-completion and completion-before-reconciliation must converge to one slot per block identity; repeated completion must be harmless.

The relevant implementation surface is `app/journal_timeline_state.ml`, with regression coverage in `test/journal_timeline_state_test.ml`. Inspect the existing replacement helpers when implementing so the merge preserves child and paging invariants without introducing a second owner for identity handling.

### Give Stale rejection a general recovery contract

Replace the obsolete delete-specific transport state and serialized representation with a state covering Stale rejection for every submitted mutation. The user already authorized the necessary changes to `logseq_overlay_db/spec/types.mli` and, where needed, the recovery contract documentation in `logseq_overlay_db/spec/database.mli`. Keep existing delete conflict semantics. Do not add backward compatibility, migrations, or fallback readers for the obsolete state.

Share settlement rules between rejection application and authoritative progression:

1. If the local authoritative checkpoint is below the rejection barrier, retain a pending state and continue pulling.
2. If a validated own-origin transaction proves execution, use the existing authoritative incorporation rules. Content equality alone must never establish execution. Preserve checks for the original batch baseline and member ordinal, including supported later superseding operations.
3. If the checkpoint has reached the barrier and authoritative evidence proves a non-delete mutation did not execute, replan its original intent against the current authoritative state. Preserve mutation identity, but create a new submission attempt and baseline. Reuse existing queued planning and dependency handling; invalid intent must produce an explicit conflict or dependency-blocked outcome.
4. Preserve the existing delete outcomes: Remote-won, No-change, or blocked conflict. A rejection delivered at or after its barrier must settle using sufficient authoritative evidence; it must not depend on seeing that exact cursor in a future batch. If the available evidence cannot safely support existing delete classification, surface the contract gap before implementation rather than guessing the outcome.
5. A record settled by rejection delivery or authoritative progression must release eligible queued work, and repeated delivery must not apply the mutation twice.

Distinguish a transport-uncertain retry from a proven-unexecuted mutation. Transport-uncertain retry keeps the frozen batch, payload, and `t_before`. Only a mutation proven unexecuted may be replanned with a new baseline. This repair must not weaken the existing recovery guarantee.

Expected files include `logseq_overlay_db/lib/database.ml`, `logseq_overlay_db/lib/types.ml`, the authorized public spec declarations, and references to the transport state in `logseq_sync/lib/pure_reducer/core.ml` and existing serialization/consumers. Determine the exact rename references before editing. Do not modify dune files or OCaml files in bonsai_flutter.

### Test at the production ownership boundary

Use TDD: first add deterministic regressions that fail on the current behavior, then implement the repair. The public probes already locate both defects at their owning state machines. Add timeline state tests and narrow Overlay Database transition tests in the existing test files; do not duplicate these regressions in transport, effect-runner, persistence, integration, E2E, or UI suites. Do not inject an already incorrect Database completion into Core and call it a pure reproduction. Use public `.mli` interfaces and existing fixtures without copying implementation logic or exposing private modules.

After the focused tests pass, run the relevant existing recovery coverage. A manual Release smoke check may verify Todo Capture, restart, subsequent writes, peer convergence, and an empty outbox; it is not a replacement for the deterministic regressions or a new automated UI suite. Remove any test records created during that check. Preserve the UX guidelines, including immediate reopening of the most recent graph.

## Alternatives considered

### Filter duplicate keys in the renderer

Rejected because it leaves the timeline's slot count and state inconsistent. The state owner can prevent the duplicate before rendering.

### Delay Capture completion or suppress incoming reconciliation

Rejected because correctness would depend on event timing and incoming data could be delayed. UUID-idempotent state updates cover both valid orders.

### Clear the local mirror whenever the queue is stuck

The approved reset was useful for recovering the audit session. It discards local queue state and does not correct the rejection transition, so it is not the product fix.

### Treat every Stale response as a fresh submission

Rejected because the original operation may already have executed. Changing the baseline without execution evidence can duplicate operations or invalidate frozen retry guarantees.

### Extend only the delete classifier's pattern match

Insufficient: handling non-delete constructors alone does not settle a barrier already passed, validate own origins, or establish when replanning is safe. Settlement must be part of the general Stale contract.

## Acceptance criteria

- Timeline regressions fail before the fix and pass afterward for both Capture/reconciliation orders and repeated completion. Every retained block key is unique, counts remain correct, expanded children and paging are preserved, and Capture still requests `Reset_to_top`.
- Public Database regressions reproduce the current non-delete classification failure and already-reached barrier stall before the fix. They cover barriers ahead of, equal to, and behind the checkpoint.
- Validated own-origin execution settles without resubmitting the operation; proven-unexecuted non-delete intent can replan and submit with a new attempt. Cover supported non-delete mutation kinds, dependent queued work, invalid replanning, and repeated transition delivery.
- Existing delete conflict outcomes remain intact, including safe settlement when rejection arrives after authoritative progress. Existing uncertain retry tests continue to demonstrate unchanged frozen batch, payload, and baseline.
- No settled Stale record leaves eligible later mutations indefinitely queued. The obsolete delete-specific state and encoding have no compatibility branch.
- Run `opam exec -- dune exec test/journal_timeline_state_test.exe`, the relevant existing Overlay Database test target, and `opam exec -- dune exec logseq_sync/test/test_sync.exe -- test 'sync recovery reproductions'`. Record actual results when implementing; the earlier green baseline is not repair validation.
- If manual Release verification is performed, Todo Capture remains usable across restart, subsequent writes reach the peer, the outbox empties, and created test data is cleaned up. Report any unverified live acceptance separately.
- Only the authorized spec `.mli` changes are made; no dune or bonsai_flutter OCaml changes are required. Existing unrelated worktree changes remain preserved.

## Implementation record

- `Journal_timeline_state.prepend_timeline_entry` uses the existing UUID replacement helper for an already-retained top-level entry. It preserves child slots, continuations, expansion, and virtualized counts while retaining Capture's `Reset_to_top` behavior. The regression exercises both reconciliation/completion orders and repeated completion.
- `Stale_rejected_pending_authoritative` replaces the delete-specific constructor and `staleRejectedPendingAuthoritative` replaces its durable encoding. Database consumers, queryable outbox classification, and Sync's existing recovery fixtures use the new state. No compatibility reader or migration was added.
- Rejection delivery and authoritative progression share ordinary Stale settlement. Continuous replay and exact normalized transaction evidence at the frozen baseline/member ordinal establish candidate origin; every preceding member of the original batch must also have origin evidence. A matching suffix following a remote first transaction cannot count as own execution.
- Executed ordinary members settle without retransmission, including a member superseded by a later member of its own batch. Proven-unexecuted intent clears the old submission baseline and encrypted payload, retains mutation identity and attempt history, and enters the existing queued replanner. Fresh submission freezes a new batch identity and the current checkpoint. Equivalent content without execution evidence produces No_change, missing dependencies block transitively, and an insertion colliding with an existing authoritative UUID blocks instead of overwriting the remote block.
- A compact private Stale batch receipt is persisted atomically with settlement. Repeated old rejection cannot affect a fresh attempt. Pending duplicate rejection retains the original barrier; a non-advancing or contradictory barrier is rejected. `Retry_group` remains reserved for transport-uncertain Submitted batches, retaining the original batch, bytes, and baseline.
- Delete conflict classification remains historical and unchanged: Remote_won, equivalent No_change, or Blocked Stale_barrier. Public authoritative progression holds unresolved submitted deletes unless a first-cursor conflict earns a durable terminal receipt. Consequently, late rejection after such progress confirms the existing receipt; an active submitted delete cannot silently lose the boundary root through normal public transitions. A semantically equivalent deletion is not sufficient to distinguish an own candidate from a peer deletion and retains the existing No_change semantics.
- Only the authorized Overlay spec declarations/documentation were changed. No dune files or bonsai_flutter OCaml files were modified. The unrelated worktree changes present at the start were preserved.

### Verification

The final verification results and commands are recorded in [the repair test report](../../../test-reports/2026-09-07-todo-capture-stale-sync/report.md).

- The timeline regression failed before repair with three retained copies of the same captured block key after repeated completion.
- All 38 new public Database regression cases fail against the exact starting implementation, reconstructed with its pre-existing worktree edits. The final implementation passes all 87 cases in `test_overlay_sync.exe`, including the existing deletion and frozen retry cases.
- The existing 11 `sync recovery reproductions` cases pass.
- A full-suite attempt exposed an unrelated transient test-peer readiness race: `transport_contract.ml` read the newly created port file before its numeric contents were available. The isolated transport case and full-suite rerun passed without a transport test or implementation change.
- The subsequent [live macOS Release verification](../../../test-reports/2026-09-07-todo-capture-stale-sync/macos-release.md) passes Todo Capture before and after restart, a subsequent status edit, peer convergence, and cleanup. Final restart opens the recent graph directly with Current / Ready / Open diagnostics and an empty outbox. Both created test records were deleted through the native UI; no graph reset was performed. A deliberately triggered live Stale rejection or lost acknowledgment remains unverified.

## Consequences

- An observed origin without validation is insufficient to finalize a mutation. Matching current content is also insufficient, especially after later authoritative edits.
- Delete classification uses historical authoritative changes. An already-passed barrier may require evidence not retained by the current contract; preserving semantics takes priority over blindly unblocking the queue.
- Replanning a rejected mutation can change dependency outcomes. Previously accepted work and unresolved dependent intent must remain distinguishable.
- Removing the obsolete serialized state intentionally gives up compatibility with persisted outboxes containing that representation. This document does not authorize another destructive graph reset.
- Timeline replacement must not discard expanded children or corrupt virtualized counts when the captured entry is already retained.
- The investigation proves two local defects and their observed recovery failure, but does not establish why the original acknowledgment was interrupted. Do not claim that fixing the UI alone repairs durable queue recovery.

## Questions

- **Answered: May the repair change the public Stale recovery specification?** Yes. During planning the user selected permission for the necessary spec adjustments. Scope is the general transport state in `logseq_overlay_db/spec/types.mli` and necessary contract documentation in `logseq_overlay_db/spec/database.mli`, while retaining delete conflict semantics.
- **Answered: Should this document advance to proposed or implementation now?** The user first requested the proposed lifecycle transition, then explicitly requested implementation with `/goal`. This record now covers that implementation.
- No additional user decision is required. The public delete state machine retains unresolved history by deferring progression, or retains a terminal proof after a causally prior conflict. The implementation preserves this ownership boundary and the existing delete outcomes.
