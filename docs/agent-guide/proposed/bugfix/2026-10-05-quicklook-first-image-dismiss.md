# Investigate native first-image dismissal

## Problem

On the isolated iOS 26.1 Simulator, actual XCTest clicks blue1, pages left to green2 and right to blue1, then sometimes closes the preview on a right gesture toward red0. Screenshots and passive selection logs confirm return to the rows. One shorter center drag run displayed red0 correctly, while a repeat using identical normal XCTest coordinates again dismissed. Thus this is not yet a proven deterministic production fix or a passing paging acceptance.

## Proposal

Keep the existing production hierarchy pending a reliable native solution. Both a navigation-root QuickLook controller and direct-modal QuickLook were tested and reverted: neither reliably prevented dismissal, and navigation-root QuickLook also replaced Save. No custom gestures, scroll tracking, synthesized index events or shared LUI changes were implemented. Preserve the independent, confirmed Photos callback isolation repair.

The native hierarchy and QuickLook gesture lifecycle own this behavior. The public save owner has no paging or UIKit dismissal event and cannot reproduce it through pure events. The narrow actual UI test is the current evidence. Complete actual page, close/reopen and full Application acceptance before merge; a single successful color sequence is insufficient.

## Alternatives considered

### Synthesize item-index events

Rejected: that bypasses the real interaction instead of validating it.

### Implement custom pager coordination immediately

Deferred: AGENTS.md requires explicit approval when native APIs cannot satisfy the requirement. Explain the limitation and review a concrete minimum proposal first.

## Acceptance criteria

- Reliable actual blue→green→blue→red and close/reopen behavior, with correct image group and retained Save/Share/Done.
- No claim that unrun Application Copy/status/Delete/Undo or single-image/failure UI paths passed.
- No merge until the required native acceptance and final-head CI pass.

## Risks

- Native overscroll/dismiss gestures and XCTest velocity can interact; the precise internal cause is unconfirmed.
- Proposed alternate containment did not fix the observed failure and must not be published as a repair.

## Questions

- Native paging remains unresolved. Any proposed custom UI coordination needs the user's explicit approval under AGENTS.md; the current work implements none.
