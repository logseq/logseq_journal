# Captured Block Missing from Timeline

## Problem

The user reports that Capture closes after saving a block in the live-account iPhone acceptance application, without visible error feedback, but the block is absent from the timeline. Successful sheet dismissal must not be treated as proof of visible or durable data.

## Decision

Classify newly created journal pages with the built-in Journal class in both outgoing transactions and optimistic page projection. Publish definitive sync rejection through the existing reducer snapshot and retain a blocked-work warning across catch-up and reopening. Preserve stale-version reconciliation. Owning-boundary regressions fail before the fixes and pass afterward; full Dune build/tests and iPhone Release build pass.

The user confirms the repaired Capture block appears and remains after waiting. Read-only device inspection confirms two new applied receipts, authoritative progress and no new pending/rejected records. The repair is installed in the original production application as well. See [the bounded acceptance report](../../../test-reports/2026-09-16-native-swiftui-standardization/batch59-capture-journal-class.md).

## Investigation and regression ownership

A read-only copy of the live acceptance graph contains a createJournalPage and insertBlocks pair submitted once at 02:55:17 UTC. Both now have `state=blocked`, `blockedReason=rejected`; no mutation receipt claims success. The original live timeline is retained. No repeated Capture or account reset was performed.

The silent rejection has an existing pure owner: `Logseq_sync_pure_reducer.Core`. Its public `Websocket_message (Tx_reject ...)`, outbox completion, sync inspection, snapshot and publication effects can reproduce missing feedback. A valid server rejection is an expected external event, not an injected incorrect result. Regression coverage for this feedback defect belongs only in `logseq_sync/test/core_contract.ml`. The original protected transactions were then replayed only against an in-memory copy through the locally compiled Logseq server transaction function. Creating the journal fails schema validation because it lacks the Journal class tag, so the server treats it as an ordinary block requiring parent/page/order. The dependent insertion consequently fails on the absent parent. Adding only `block/tags -> logseq.class/Journal` to the diagnostic replay makes both operations apply.

Journal transaction construction belongs to `Logseq_overlay_db.Database.commit_local`. The worker and synchronization pure reducers delegate the typed Create_journal_page operation; their public state does not construct or expose page tags. The narrow public owning boundary is therefore Database.commit_local followed by its public outbox submission and Database.get_pages. Submission wires prove what the server receives; page.tags independently checks that the optimistic projection agrees. An initial get_pages-only assertion exposed the separate empty optimistic tag list, so it was insufficient alone to cover outgoing transaction construction. Extend the existing journal-creation regression there only; do not duplicate it in worker, wire, persistence or UI regression suites. The server replay is diagnostic acceptance evidence, not a second permanent regression.

## Alternatives considered

### Repeat the user's Capture submission

Rejected because it can duplicate content without establishing whether the original operation succeeded.

### Reset the account or reinstall the application

Rejected because it destroys useful live evidence and can hide a feed update defect.

## Acceptance criteria

- Determine whether the original saved mutation reached local storage and identify the owning visibility failure without publishing private content.
- Reproduce the cause through an existing deterministic public boundary, or document why native/runtime observation is necessary.
- Verify the repaired save visibly appears in its intended journal and survives appropriate refresh, without duplicate writes or lost drafts.
- Preserve retained List navigation and the explicit Capture save-to-top behavior; do not add scroll-position restoration.
- Run relevant tests, builds, formatting checks and decision-document validation.

## Risks

- Restarting or refreshing before observing the defect can erase evidence.
- The live graph is private; collect only data needed for diagnosis and do not log credentials.
- Offline fixture success does not prove live refresh ordering.

## Questions

None. The user confirmed the original failure and successful Capture acceptance after the repair.

## Consequences

New-day Capture satisfies server journal validation, and rejected saves no longer disappear silently. Original rejected mutation payloads and submission counts remain intact without automatic replay; normal catch-up updates their syncRevision metadata. Native List retention and explicit Capture save-to-top are unchanged. The wider UI standardization goal retains its remaining unlock-retry, layout/input and performance gates.
