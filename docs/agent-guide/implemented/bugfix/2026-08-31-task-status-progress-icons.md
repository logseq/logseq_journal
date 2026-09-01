# Task Status Progress Icons

## Problem

The four task-status actions currently mix unrelated icon shapes: an outlined
circle, an outlined square, a filled pending circle, and a filled check circle.
The inconsistent silhouettes and weights make the status sequence harder to
scan as a progression.

## Proposal

Use one circular progress vocabulary for the four status actions:

- `No_status`: Flutter `Icons.remove_circle_outline`.
- `Todo`: Flutter `Icons.radio_button_unchecked`.
- `Doing`: Flutter `Icons.incomplete_circle`.
- `Done`: Flutter `Icons.check_circle_outline`.

Add exactly these icons to `Material_icon_catalog`, using the code points from
the pinned Flutter 3.44.8 SDK, and update the timeline status-action mapping.

## Decision

Adopt the proposed four-icon circular progress vocabulary. Remove the three
catalog roles that become unused by the application (`Check_circle`,
`Circle_outlined`, and `Pending`) instead of retaining obsolete aliases.

## Alternatives considered

### Keep the current mixed icon set

This requires no code change, but retains inconsistent shapes and does not
communicate a clear progression.

### Use a runtime circular progress widget

This could render arbitrary completion percentages, but task status is a
four-state enum rather than numeric progress. It would add complexity without
improving the requested status mapping.

## Acceptance criteria

- The status actions render `remove_circle_outline`,
  `radio_button_unchecked`, `incomplete_circle`, and `check_circle_outline` in
  `No_status`, `Todo`, `Doing`, and `Done` order.
- The catalog code points match Flutter 3.44.8 `Icons.*.codePoint` values.
- Existing status-action semantics, behavior, layout, and colors remain
  unchanged.
- Focused OCaml tests and the Flutter icon-font verification pass.

## Risks

- Hard-coded code points can become stale after a Flutter SDK upgrade; the
  existing SDK verification must continue to guard the catalog.
- `remove_circle_outline` can imply removal without its adjacent `No status`
  label, so the action must retain its current semantic and visible label.

## Implementation evidence

The RED test rendered the existing `No_status` icon as U+EF53 and failed
against the required U+E518. The catalog and timeline mapping now render:

- U+E518 (`remove_circle_outline`) for `No_status`.
- U+E504 (`radio_button_unchecked`) for `Todo`.
- U+F051E (`incomplete_circle`) for `Doing`.
- U+E15A (`check_circle_outline`) for `Done`.

The focused semantics test, full OCaml test suite, source-boundary checks,
Material icon font artifact verification, generated-host check, Flutter test
suite, Flutter analysis, and the real-runtime centered full-bleed swipe-action
test pass.

## Questions

- None. The user supplied the exact four-icon mapping.

## Consequences

- All four task-status actions use circular silhouettes with a visible
  progression from unset through incomplete to complete.
- The application catalog exposes only the newly required status roles rather
  than preserving the replaced status icon roles.
- Status behavior, labels, colors, and layout are unchanged by this decision.
