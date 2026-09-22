# Hide Native Journal Row Separators

## Problem

Batch 30's signed production iPhone screenshot shows six Journal row separators,
exceeding the maximum of three dividers in docs/ux-guidelines.md. JournalList
already requests hidden separators inside its child builder, but the visible
native rows do not honor that request. The existing native device observation
is the failing visual acceptance.

## Proposal

Apply native row/section separator visibility at the actual List row composition
boundary. Keep native List, navigation, swipe actions and context menus. Remove
ineffective duplicate placement rather than adding a compatibility path.

The production owner is JournalList's SwiftUI row projection. Public pure
JournalListViewport and Journal timeline events/state/effects own identity,
visibility and pagination, and expose no platform separator visibility. Their
outputs cannot reproduce this UIKit rendering defect. Verify through the existing
production native device acceptance and before/after screenshots. This small
presentation-only correction does not justify duplicate reducer or transport
tests, or a separate screenshot-analysis implementation.

## Questions

- None. This implements the existing divider limit within the approved UI scope.

## Acceptance criteria

- The same production iPhone Journal screen has no row separators after the fix.
- Row opening/back, destination selection and native swipe/context actions remain
  available in the current device acceptance.
- Signed iPhone Release build succeeds; no OCaml, protected spec, Dune or SDK
  source changes are needed.
- Record the failing and passing visual evidence without claiming the remaining
  accessibility or performance matrix is complete.

## Risks

- SwiftUI list traits must reach the concrete row despite conditional builders.
- The current native landscape screenshot export remains cropped; it is not a
  reliable full-layout acceptance artifact.

## Alternatives considered

### Replace List with custom scrolling rows

Rejected because native gestures and navigation are required and the separator
behavior has a native modifier.

### Hide separators only on the inner navigation content

The current screenshot demonstrates that this placement is ineffective in this
composition.

## Rejection reason

The user explicitly deferred the divider issue; the uninstalled experimental modifier change was reverted.
