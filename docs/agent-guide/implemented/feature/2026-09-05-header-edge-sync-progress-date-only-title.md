# Header-Edge Sync Progress And Date-Only Title

## Problem

The Journal header currently places the sync progress indicator inside the
centered app-bar title column, directly below the combined `Today · <date>`
text. The indicator is therefore constrained to the title region instead of
occupying the header's bottom edge. Its width and vertical position can change
with the title and the space reserved for leading and trailing actions, so it
does not provide the intended stable, header-wide connection cue.

The visible `Today` prefix also repeats context already communicated by the
Journal route and consumes scarce horizontal space. On narrow windows, at large
text scales, or when the error and account actions are both present, the prefix
makes the useful date more likely to clip. The header should prioritize the date
itself.

The implemented 2026-08-31 sync-progress decision specified a two-logical-pixel
indicator across the pinned header's bottom edge. The later migration to an
earlier `Ui.Material.App_bar.sliver` retained the indicator by moving it into the
title because that constructor exposed only title, leading, and action slots.
The updated `bonsai_flutter` API now exposes
`bottom:(Widget.t * float)`, backed by a full-width independently pinned bottom
region below the retained toolbar. The application can therefore restore the
intended edge placement without approximating it inside the title slot or
constructing a custom app bar.

## Proposal

Change the Journal header presentation in two coordinated ways:

- display the date without the visible `Today` prefix; and
- render the existing flat, indeterminate sync progress indicator across the
  full bottom edge of the pinned header instead of as a child of the centered
  title column.

Retain the current sync visibility contract: exactly `Connecting` displays the
indicator, while `Offline`, `Pulling`, `Submitting`, `Current`, `Paused`,
`Failed`, and an absent sync snapshot do not. Retain its two-logical-pixel
thickness and Material theme ownership. The indicator must remain attached to
the pinned header and visible regardless of scroll position. Its appearance and
disappearance must not insert a separate timeline row, move Journal content, or
create an additional divider.

Always provide `Ui.Material.App_bar.sliver` with a two-logical-pixel bottom
region. Render the existing flat indeterminate Material linear progress
indicator as that region's content while connecting, and render an empty widget
there for every inactive phase. Keeping the bottom region present in both states
preserves the header and timeline geometry when connection state changes. Pass
the region and its height directly as
`~bottom:(progress_or_empty, sync_progress_height)`; do not add an application
preferred-size wrapper or a second sliver.

For the active Today timeline, use the existing date subtitle as the complete
visible title. Update the date-context semantics so assistive technology hears
the same truthful date copy and does not announce the removed `Today` prefix.
Keep the header as a view-only element with no focus or activation action.

Preserve the built-in Material app-bar ownership, account and optional error
actions, centered date, pinned/non-floating/non-snapping behavior, theme-owned
colors, and compact square presentation. Remove the obsolete combined-title
formatting and title-owned progress composition; do not retain them as fallback
paths.

Use the updated `Ui.Material.App_bar.sliver` bottom region as the supported
component boundary. Update the application's `bonsai_flutter` revision and
generated host through the normal dependency and synchronization workflow before
using the new argument. The implementation must comply with
`docs/ux-guidelines.md`, must not hand-edit generated host code, and must not
modify OCaml files in the `bonsai_flutter` repository.

## Decision

Use Bonsai Flutter revision `84e588d0698ad3543d9a93ee2f9cf3a1ba82d05b`
for the application and worker dependency pins and lockfiles. The installed
framework, test support, host tool, and generated host already use this revision;
`bonsai-flutter sync-host` confirms that the generated host is current.

The revised native sliver API no longer accepts the former Material
`variant`, `shape`, and `density` arguments. Preserve the existing 64-pixel
expanded and collapsed toolbar region explicitly, with the native 56-pixel
toolbar, centered title, square native presentation, and theme-owned colors.

Render the Today context subtitle as the complete visible and spoken date.
Keep the unused selected-context API unchanged. Pass a permanent two-pixel
`bottom` region containing either the existing flat indeterminate progress
indicator or an empty widget. Clip the active indicator with the standard
hard-edge rectangular clip: pixel tests demonstrated that the Material painter
otherwise paints three additional rows below its two-pixel layout bounds.
This clip does not add a preferred-size wrapper, header, or timeline row.

Export full and incremental frames from the actual OCaml `Journal_header.sliver`
through the existing headless semantics-test executable. The Flutter layout test
renders these frames with the standard Bonsai renderer, including repeated
inactive/connecting transitions. This provides executable runtime layout and
pixel evidence without depending on the older, opt-in whole-application golden
lane whose fixture executable is no longer present in the repository.

## Alternatives considered

### Keep the indicator below the centered date

This is the current implementation. It retains the built-in app-bar boundary,
but the indicator is only as wide as the title region and is not anchored to the
header edge. It does not meet the requested visual placement.

### Add a progress row to the timeline

A normal sliver or timeline row can span the viewport, but it scrolls away and
changes content geometry. It would report header-level connection activity in
the wrong ownership boundary. The new app-bar bottom region provides the needed
full-width pinned behavior directly.

### Replace the Material app bar with a custom header

A custom stack or persistent-header implementation could place an overlay at an
exact edge. It would duplicate built-in Flutter app-bar behavior and conflict
with the project preference for the appropriate built-in component. The updated
Material app-bar API makes this unnecessary.

### Keep `Today` only in accessibility semantics

Removing `Today` visually while continuing to announce it would make visible and
spoken labels diverge without adding necessary meaning. The date is sufficient
for both presentations unless product requirements explicitly retain relative-day
context for assistive technology.

### Replace `Today` with a shorter separator or icon

Changing the decoration would still consume horizontal space and preserve
redundant context. A date-only title is simpler and gives the meaningful copy the
largest available width.

## Acceptance criteria

- The active Today Journal header displays the existing date subtitle and does
  not display or semantically announce `Today`.
- The date remains centered, single-line, view-only, and truthfully labeled for
  accessibility; narrow width, RTL, and supported text scales do not cause it to
  overlap header actions.
- During exactly the `Connecting` sync phase, one flat indeterminate Material
  linear progress indicator spans the header's full content width at its bottom
  edge.
- The indicator remains exactly two logical pixels tall and pinned with the
  header in every scroll state.
- The indicator is absent for `Offline`, `Pulling`, `Submitting`, `Current`,
  `Paused`, `Failed`, and when no sync snapshot exists.
- Toggling the indicator does not add a timeline item, shift timeline content,
  change scroll ownership, or add a divider. The rendered screen remains within
  the project limit of three dividers.
- The Account menu and optional error action retain their placement, semantics,
  tooltips, hit targets, and behavior.
- The implementation uses the appropriate built-in Material/Flutter component
  boundary, passes a fixed two-logical-pixel bottom region through
  `Ui.Material.App_bar.sliver`, and removes the obsolete combined-title and
  title-owned indicator paths without a compatibility layer.
- The two-logical-pixel bottom region remains present with an empty child during
  inactive phases, so entering or leaving `Connecting` does not change the
  header extent or timeline scroll geometry.
- Focused view, semantics, narrow-width, large-text, RTL, and runtime layout
  tests verify the visible copy and physical edge placement rather than only the
  presence of test IDs.
- No Dune file, OCaml file under `spec/`, hand-edited generated host file, or
  OCaml file in the `bonsai_flutter` repository is modified.

## Risks

- The updated bottom is rendered as an independently pinned region below the
  native app-bar toolbar. Runtime tests must prove that its full-width geometry,
  ordering, and pinned lifetime read as one header on supported viewport sizes.
- Conditionally omitting the bottom argument would change the header extent by
  two logical pixels when sync state changes. The inactive empty child is
  required to keep geometry stable.
- The application dependency revision, generated Flutter host, OCaml runtime,
  and Dart renderer must all use the protocol version that supports the bottom
  region; a partial upgrade will reject or misdecode frames.
- Removing `Today` reduces explicit relative-day context. The displayed absolute
  date must remain unambiguous and locale-appropriate.
- A full-width animated indicator can visually cover an existing bottom boundary
  if its layering and inactive state are not tested on light, dark, and
  high-contrast themes.
- Runtime geometry may differ from the OCaml widget tree. Flutter-side layout or
  golden evidence is required to prove that the indicator reaches both header
  edges and remains attached while scrolling.

## Consequences

The header now prioritizes the date in both visual and accessibility output.
Connection activity occupies a permanent bottom slot and remains pinned without
moving timeline content as sync phases change. The standard clip contains the
Material painter's overflow while retaining its theme-owned styling. Header
layout tests run in the default Flutter suite using real OCaml frames, so this
coverage no longer depends on enabling the older whole-application golden lane.

## Verification

- `dune build @all` and `dune runtest` pass.
- OCaml header tests cover date-only visible and spoken copy, view-only semantics,
  every sync phase, and the permanent two-pixel bottom region.
- `flutter analyze --no-pub` reports no issues.
- `flutter test --no-pub` passes 55 tests, including all 32 new header cases;
  the existing seven opt-in whole-runtime golden tests remain skipped.
- Header renderer coverage includes light, dark, and high-contrast themes;
  390- and 320-pixel widths; text scales 1 and 3.2; LTR and RTL; the Account action
  with and without Error info; and scroll offsets 0, 80, and 1200.
- Incremental frame transitions preserve the scroll position, scroll extent,
  timeline anchor, date placement, and action targets. The progress render box
  spans the full header width at its bottom edge; pixel comparisons confirm
  painting remains within exactly its two reserved rows in all four themes.
- Button event bindings, semantics, tooltips, minimum hit targets, and the lack
  of an additional header divider are verified through the Flutter renderer.
- The normal Bonsai Flutter execution workflow builds and verifies the macOS
  native artifact. `bonsai-flutter sync-host --check`, OCaml formatting, Dart
  formatting for the new test, and `git diff --check` pass.
- No Dune file, OCaml file under `spec/`, hand-edited generated host file, or
  OCaml file in the Bonsai Flutter repository was changed for this decision.

## Questions

None. The application has only one runtime Journal-header call site, for the
Today timeline, so this change removes that literal prefix and leaves the unused
selected-context API outside the feature scope. The updated
`Ui.Material.App_bar.sliver` bottom region determines the progress-indicator
ownership boundary.
