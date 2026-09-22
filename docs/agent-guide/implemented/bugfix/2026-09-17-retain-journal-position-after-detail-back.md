# Retain Journal Position After Detail Back

## Problem

Physical iPhone acceptance on the batch 39 Release binary reproduces a Journal
position reset. Scroll to approximately row 60 in the isolated 500-root graph,
open row 60, then use native Back: the Journal shows the first root. A prior run
at row 500 exhibits the same reset. Closing Capture and returning from the
background independently preserve the observed rows 33–46. The diagnostic
XCTest completes successfully because it collects observations; it does not
assert successful restoration. Restoration acceptance is failed.

Evidence: `batch41-anchor.xcresult`, its screenshots and diagnostic source under
`docs/test-reports/2026-09-16-native-swiftui-standardization/`.

## Original ownership investigation

`Journal_routes` owns the logical navigation anchor; `Journal_timeline_state`
owns visible indices. `Application.back_state` invokes `return_from_detail` and
preserves timeline state. Existing public route completion/Back and timeline
return/visibility tests pass on the current build. These checks do not reproduce
the physical reset and cannot model SwiftUI List mount/visibility callbacks.

`JournalList.Resource` and `JournalListViewport` own the native restoration
command and visibility reporting. Installation requests restoration only for its
first nonempty snapshot; resource lifetime and native List lifetime may differ.
This is a candidate boundary, not yet a proven cause. Establish actual lifecycle
ordering and whether visibility overwrites the retained logical index before
choosing a change. Do not inject an incorrect external range as a supposed pure
reproduction or change production ownership just to classify a test.

## Decision

Keep Journal and Favorites mounted in the existing native NavigationStack when
opening detail. Dispatch the public open event through a plain native row Button
and let the application route update push the destination. On Back, reveal the
same List without recording or replaying its scroll position.

Remove obsolete route anchors, Favorites anchor reconciliation and unused
timeline restoration/focus fields. Keep pagination visibility and explicit
Capture scroll-to-top behavior. See the investigation below for failed
restoration experiments and the successful native navigation control.

## Alternatives considered

### Ignore the reset because navigation succeeds

Rejected: UI-16 requires the previous list UI to remain intact on Back.

### Force every property update to scroll to the saved anchor

Rejected: ordinary paging and visibility updates would interrupt user scrolling.

## Acceptance criteria

- Record the failing behavior at its actual owner before changing production code.
- Fix detail return and verify a middle-list and last-root return on the iPhone.
- Preserve Capture dismissal, lifecycle return and explicit Capture scroll-to-top behavior.
- Keep regression coverage at the narrowest reproducing boundary; no duplicate
  reducer/integration/UI regression suites for the same defect.
- Rebuild/sign/install the changed Release binary and record its hashes.

## Consequences

Back needs no saved position or scroll replay. Row actions retain fresh event
admission through the native Resource. Native UI lifecycle acceptance remains
the regression boundary; reducer data and mutation coverage stays intact.
The exact SDK NavigationLink identity issue is not repaired or claimed resolved.

## Risks

- Row actions must use the latest admitted native context after navigation.
- Visibility still drives pagination; removing restoration must not remove
  visibility reporting or Capture's explicit scroll command.

## Questions

- None. The user explicitly selected UI retention and obsolete-code cleanup.

## Reproduction boundary confirmed in batch 42

A scratch public-interface probe builds 500 roots, observes ranges 53–65 and
499–500, opens/completes/returns from detail, and checks the retained route anchor,
timeline index and scroll generation. Both retain the correct state. No failing
pure regression is justified at that boundary.

Physical diagnostic logging shows a different native sequence: emitted ranges
accumulate from 0–12 to 0–64 while the displayed viewport reaches row 60. The
Resource identity survives detail push/pop; installation and appearance still
receive the first-root anchor. Journal's row disappearance does not remove its
visibility membership, unlike the SDK native List. The narrowest exercised
reproduction is the actual SwiftUI List lifecycle, so the regression lives in
`apple-tests/native-list/JournalListNavigationAcceptance.swift`; no duplicate
reducer or transport regression is added.

First clear native visibility on row disappearance, then restore the retained
anchor when the List appears again. Do not replay scroll restoration on ordinary
property updates. Apply the same shared-viewport lifetime correction to Favorites.
Retain all three native acceptance cases before implementation: repeated middle
return, final-root return and Capture/lifecycle/scroll-to-top behavior.

The first post-change Capture case incorrectly assumed that an inserted block must
be the first row. The public timeline insertion path preserves sibling order and
explicitly scrolls to index zero; previous physical acceptance already showed
new Capture after existing fixture rows. Correct the test to assert that existing
scroll-to-top contract, and separately inspect exact saved outbox content. Retain
the failed expectation as a test-design failure, not a production fix.

The first implementation clears disappearance and replays a row-to-top restore
on appearance. Physical repetition proves it insufficient: first return retains
the chosen row, but the next return aligns an earlier long row to its top and
loses the chosen row. Retain that failed run. Prefer native SwiftUI ScrollPosition
retention over repeated row-to-top commands; prove its actual List behavior before
accepting it. A separate last-root query exceeded XCTest's 128-character identifier
limit; use an exact-label NSPredicate and retain the original harness failure.

## User-directed correction and final design

The user explicitly requests retaining the existing UI while detail is pushed,
without recording or restoring scroll position, and removing the obsolete code.
The native Button control using the existing programmatic NavigationStack passed
repeated physical iPhone push/pop with no restoration commands. Use that path
for Journal and Favorites, with plain native row buttons. This supersedes the
previous NavigationLink preference for these collections. The precise SDK link
identity failure remains unproven; no SDK change is needed for this solution.

Remove route anchors, Favorites anchor reconciliation, unused timeline anchor
policy/focus restoration fields, and the native initial-anchor wire property.
Keep loaded timeline data, pagination visibility, fresh row action dispatch and
explicit Capture scroll-to-top commands. Do not introduce ScrollPosition or
appearance-time scroll replay. Existing obsolete policy assertions are removed;
all data, request, mutation and pagination coverage remains.

Physical acceptance must cover repeated middle and final-root return, Favorites,
Capture dismissal, lifecycle return and explicit Capture scroll-to-top. Compare
row frames across Back to check position retention rather than mere existence.

## Implementation and verification

Implemented the final user-directed design. All four native iPhone UI cases pass
on the final binary; repeated Journal and Favorites return also pass visual
macOS checks. Full OCaml tests, native viewport checks, formatting and both Apple
builds pass. Evidence and failed attempts are recorded in
`docs/test-reports/2026-09-16-native-swiftui-standardization/batch42-list-ui-retention.md`.
The production iPhone app was installed before the user withdrew the device; its
new cold start and isolated Capture outbox readback remain unverified. These do
not imply completion of the broader standardization acceptance.
