# Asset Notice Coalescing

## Problem

The asset transfer reducer correctly emits availability for an already Ready asset, followed by demand acceptance. The Worker adapter places both independent facts in one latest-value topic; acceptance replaces Ready before the UI drains. Several assets and consumers can overwrite each other in the same way. The simulator trace reproduced both accepted requests without their Ready delivery.

## Decision

Keep the six bounded Worker topics and latest-value behavior for existing snapshot topics. Add an optional payload merge policy, applied under the existing mailbox lock and retaining the newest event envelope. For the asset topic, merge pending latest facts separately by scope, consumer and asset, demand admission, upload operation, and capacity. Retain arrival order among the surviving facts. Deliver the batch through the existing asset consumers. Bound pending distinct facts at 4096; exhaustion fails the Worker explicitly instead of silently dropping facts.

The public Asset_transfer/Core reducers already emit both correct facts. The missing ownership boundary is the coalesced Worker mailbox. Regressions will exercise that public mailbox with real asset notices and the same production merge policy; no duplicate reducer or persistence tests will be added. Initial RED uses the existing replacement behavior; GREEN wires the production merge policy at that boundary.

## Alternatives considered

### One topic per asset or consumer

Dynamic topics exceed the fixed Worker topic bound and still conflate acceptance with availability.

### An unbounded FIFO

Preserves unnecessary intermediate download states and can grow indefinitely while the UI is suspended.

### Reordering acceptance before Ready

Only hides one ordering; multiple assets, failures, and upload notices still overwrite one another.

## Consequences

Independent facts survive until drain, intermediate states of the same fact coalesce, and snapshot topics remain unchanged. Pending payloads have an explicit 4096-fact limit. No Swift, dune, or spec/ OCaml file is changed.

## Acceptance criteria

- Ready followed by acceptance preserves both facts.
- Distinct assets and consumers survive a burst; repeated updates retain their latest state in arrival order.
- Scope identities remain separate, and capacity and upload facts do not erase availability.
- Existing snapshot topics retain latest-value replacement and Worker event fencing remains intact.
- Focused regressions and build pass; a real simulator image reaches its preview.

## Risks

- More than 4096 distinct undrained asset facts terminates the Worker with an explicit error. This is a hard bound, not silent truncation.
- The batch is process-local; public database protocol and pure reducer specs are unchanged.

## Questions

All required scope decisions are answered by the user's explicit fix authorization: local isolated branch only, no push, PR, or physical iPhone installation. Preserve the existing UI redesign and fetch current GitHub main before code edits.

## Evidence

Five deterministic public-mailbox regressions failed for notification loss or silent overflow before implementation. All eight service tests now pass. The complete build passes; full runtest retains the one pre-existing V.progress source-text mismatch. A real graph file now shows ML and actual 47.2 KB, its camera image renders, and tapping that image shows full Quick Look content. The ML type uses Quick Look's system fallback; it is not claimed to render source text. Both previews were dismissed back to the timeline. The historical screenshots were task-local validation evidence, retained outside the repository. GitHub main was fetched before both test and implementation edits and remains a33d782; the isolated branch includes it.
