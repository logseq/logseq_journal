# Timeline Date Typography Hierarchy

## Problem

The Journal timeline renders a calendar date and weekday as one title, such as
`2026-09-06, Sun`. Equal typography gives the weekday the same emphasis as the
date. Repeated historical headings compete with journal content and its status
rails instead of acting as quiet section markers.

The user supplied a design that separates the primary date from secondary
weekday metadata: a centered two-line current date and a lighter inline date for
historical sections. This proposal implements the parts supported by the current
bonsai_flutter public API. Implementation and validation are recorded below.

### Current implementation

- `app/journal_calendar.ml` owns Gregorian validation and weekday calculation.
  `format_journal_day` returns one `YYYY-MM-DD, Ddd` string. Application passes
  that string into both the header context and timeline day-label callback.
- `app/journal_header.ml` renders `Context.subtitle` as a single clipped Text.
  It currently ignores the supplied typography and text scale. Its built-in
  Material sliver app bar has 64dp expanded/collapsed heights, a default 56dp
  toolbar, and a permanently reserved 2dp bottom region for sync progress.
- `app/journal_timeline.ml` renders each historical heading as one Text with
  `typography.day_heading`. Today has no duplicate heading in the list.
- `app/journal_visual_tokens.ml` gives historical headings the same size and
  weight as header-title tokens: 22sp/w600 for Dense and Balanced, 24sp/w600 for
  Comfortable. The pasted screenshot's estimated 28–30sp/w700 is not the
  current source contract. Heading padding is currently 20dp before and 4dp
  after; row content has its own 6dp vertical padding.
- `Journal_timeline_state.extent_geometry` obtains heading heights from
  `Journal_visual_tokens.fixed_extent`. Rendering and virtual-list geometry must
  change together when typography or section spacing changes.

Related decisions are the
[timeline hierarchy decision](../../implemented/bugfix/2026-08-28-journal-timeline-visual-hierarchy.md)
and the
[header progress decision](../../implemented/feature/2026-09-05-header-edge-sync-progress-date-only-title.md).
This proposal replaces their relevant date typography and single-line title
requirements while retaining their other behavior.

## Proposal

On 2026-09-06, the user selected implementation using only currently supported
bonsai_flutter capabilities. Custom letter spacing, tabular figures, and exact
alphabetic baseline alignment are excluded from this proposal. The remaining
date format, hierarchy, layout, spacing, and accessibility requirements below
define the complete agreed scope. No framework upgrade is a prerequisite.

### Display contract

Use `YYYY.MM.DD` with zero-padded month/day and uppercase English weekday labels
`MON` through `SUN`. Remove the visible comma. Date punctuation is presentation
only: journal-day integers, page names, identifiers, storage, routes, sorting,
calendar ownership, and block timestamps retain their existing meaning.

At default text scale, use the following dedicated date styles across all three
typography presets. Keep existing preset-dependent body typography.

| Role | Size | Weight | Line height | Foreground |
| --- | --- | --- | --- | --- |
| Current date | 24sp | w600 | 1.15 / 27.6dp | Theme primary text |
| Current weekday | 12sp | w500 | 1.2 / 14.4dp | Theme text at 0.55 opacity |
| Historical date | 20sp | w400 | 1.2 / 24dp | Theme primary text |
| Historical weekday | 12sp | w500 | 1.2 / 14.4dp | Theme text at 0.50 opacity |

Use the font's default tracking and numeral widths. Do not insert literal spaces
between weekday letters or simulate fixed-width digits. Use theme-aware foregrounds rather than
hard-coded black or the reference's light-mode gray examples. In high-contrast
mode, increase weekday contrast while retaining the size/weight hierarchy.

### Current date header

The centered title becomes:

```text
2026.09.06
   SUN
```

Use a compact centered column with a 2dp gap. The specified line boxes total
44dp at scale 1.0; the reference's approximately 47dp is an estimate, not an
additional height requirement. Start with the existing 64dp app-bar region and
56dp toolbar: the default-size column can fit without automatically adding
another 17dp to the entire header. Verify actual native layout and font metrics.

At larger supported text scales, grow the native toolbar and expanded/collapsed
heights together for the effective title scale. On 2026-09-06 the user explicitly
selected keeping dates on one line and limiting their enlargement when width is
insufficient. Apply that width budget to the current title and historical date
rows while leaving body text scaling unchanged. Respect the native Material
app-bar title scale cap when calculating its text styles and geometry; do not
apply inverse system scaling a second time. Verify both native action targets at
default and enlarged system text sizes.

Retain the built-in pinned Material app bar, account/error targets, and the
existing sync phase behavior. Its reserved 2dp bottom region remains outside the
date column and must not change height when progress becomes visible. Do not
reintroduce the visible `Today` prefix or make the title interactive.

### Historical section headings

Render the two parts in one horizontal row using native layout. Center the
smaller weekday vertically within the date line's height using supported
alignment and box widgets; exact alphabetic baseline alignment is not required:

```text
2026.09.05   SAT
2026.09.04   FRI
```

Use an actual 14dp horizontal layout gap between the date and weekday. Preserve
the logical content-leading alignment shared with top-level journal text, with
RTL mirroring. Do not copy the screenshot's approximate x=68 coordinate: the
current layout uses `profile.content_leading`, which is 24dp on narrow widths
and 32dp otherwise. The status rail remains offset from the content axis.

For the first iteration, choose visible line-box gaps of 26dp from preceding
block content to the heading and 16dp from the heading to following block
content. Both sit within the supplied ranges of 24–28dp and 14–18dp. Account for
the row's existing padding rather than adding those gaps on top of it. These
values are a target rhythm; the actual source currently has smaller heading
padding, so this is not described as a guaranteed reduction everywhere.

For adjacent headings representing genuinely empty days, use one 22dp gap
between their line boxes, within the supplied 20–24dp range. Do not add the
normal before/after gaps together. A day with an active continuation is still
loading, not known empty, and keeps its loading affordance.

The owner of slot geometry must determine the adjacent-heading spacing using
the same retained slot context as rendering. Do not let only the visible window
decide emptiness: a heading at a virtualization boundary must have the same
height before and after scrolling into view. Keep stable day keys and existing
heading semantics. Today remains represented only by the top header.

### Data and implementation boundaries

Expose structured date presentation from the existing calendar owner: numeric
display text, weekday text, and a coherent accessibility label. Calculate the
weekday from the validated civil day using the existing calendar logic. Do not
split or reparse the old formatted label and do not add Dart timezone conversion.

Update the date-related Application wiring, `Journal_header.Context`, and
`Journal_timeline.view` together so the views consume the parts explicitly.
Replace the obsolete combined display-label path and its callers; do not add a
second legacy renderer, compatibility formatter, or migration. An unavailable
calendar still displays a truthful unavailable state without an invented date
or weekday. Keep invalid-date handling explicit.

Expected implementation touchpoints are `app/journal_calendar.ml/.mli`,
`app/application.ml`, `app/journal_header.ml/.mli`,
`app/journal_timeline.ml/.mli`, and `app/journal_visual_tokens.ml/.mli`.
`app/journal_timeline_state.ml/.mli` may need geometry changes for adjacent empty
headings. Do not introduce new files solely to wrap a pair of labels.

### Supported framework scope

Read-only inspection of the installed
`/Users/rcmerci/.opam/bonsai-flutter-v017-exact/lib/bonsai_flutter/ui/` interfaces
found a concrete gap:

- `style.mli` exposes size, weight, line height, and color, but no letter spacing
  or font features.
- `widget.mli` exposes `rich_text : string list -> t` without styled spans, and
  its public row/Flex API does not expose alphabetic baseline alignment.
- `material.mli` does expose `toolbar_height`, so accommodating a taller native
  toolbar does not require a custom header.

The user resolved this gap by excluding custom tracking, tabular figures, and
exact historical baseline alignment. Use separate styled Text widgets, native
columns/rows, supported box alignment, opacity, padding, and native toolbar sizing
for the agreed design. Do not wait for or upgrade the framework for those omitted
details, and do not introduce a capability switch or alternate renderer.

This task does not authorize modifying OCaml files in the bonsai_flutter repo,
OCaml files under `spec/`, or any dune file. Do not work around the gap with
private wire payloads, generated-host edits, literal letter spacing, or guessed
vertical offsets. The framework limitation no longer blocks this proposal.

### Accessibility and verification

Expose one readable date-and-weekday announcement for each heading; avoid
duplicate child announcements or spelling weekday letters individually.
Retain historical heading level 2 and sort order, and keep the top title
view-only. Preserve chronological reading order in RTL while retaining the
specified numeric date order.

Validate using existing date, adaptive layout, semantics, and header layout
coverage where applicable. Update assertions that encode the replaced combined
date string, shared header/day typography, or single-line title. Do not add
tests that only repeat numeric style constants. Use rendered visual inspection
for row alignment, contrast, whitespace, and hierarchy; do not claim reducer tests
can verify typography.

Check a normal populated timeline, adjacent empty days, a loading day, retained
window boundaries, midnight rollover, month/year transitions, light/dark themes,
high contrast, RTL, narrow widths, and supported enlarged text. Existing header
sync/layout tests should continue to establish stable action and progress
geometry. For any geometry/state defect found during implementation, first
identify and reproduce it through the public pure owner; follow the repository's
exclusive pure-reducer regression rule without duplicating coverage in UI or
integration tests.

Comply with `docs/ux-guidelines.md`: use the appropriate built-in Flutter
components, add no dividers, preserve the maximum of three dividers, and retain
most-recent-graph launch behavior.

## Decision

The calendar exposes numeric date, uppercase weekday, and accessibility text from
validated civil dates. Header and timeline views consume the structured parts.
Native semantics merges the rendered date and weekday without repeating a parent
label. Weekday opacity increases in high-contrast mode. The timeline owner derives
spacing from retained neighbors, including across a clipped retained boundary.
The visual profile shares the effective historical date scale with rendering.

See [implementation validation](../../../test-reports/2026-09-06-proposed-docs-validation.md).

## Alternatives considered

### Change only punctuation

Replacing hyphens with dots leaves the weekday and historical headings equally
prominent. It does not deliver the requested hierarchy.

### Keep both current-date parts on one line

This saves vertical room but discards the defining two-line top header in the
supplied design. The small second line can fit the existing default toolbar.

### Require every typography detail from the reference

The current public API cannot fulfill custom tracking, tabular-figure, and exact
baseline requirements. Waiting for a framework release would delay the supported
layout and hierarchy improvements. The user selected the supported scope instead.

### Build a custom app bar or emulate text metrics

Native toolbar sizing already exists. Custom header behavior and hard-coded
baseline offsets would add unnecessary layout ownership and break across fonts
or text scales. Use supported built-in layout capabilities.

## Acceptance criteria

- The top header shows a centered `2026.09.06` above `SUN`, with the specified
  24sp/w600 and 12sp/w500 styles and a 2dp gap at default scale.
- Historical dates show `2026.09.05` and `SAT` in one vertically centered row with a
  14dp gap, using 20sp/w400 and 12sp/w500 respectively. No comma or mixed-case
  weekday remains in these visible headings.
- Text uses default font tracking and numeral widths. Separate labels and their
  alignment use supported public widgets, without synthetic baseline offsets,
  spaced-out weekday strings, or a framework upgrade.
- Historical dates remain on the content axis and visibly subordinate to the
  current date. Body text, block timestamps, and status rails retain their roles.
- Default section spacing meets the selected 26dp/16dp populated-day rhythm and
  22dp adjacent-empty-heading gap without doubled padding or loading suppression.
- Rendered heading sizes and virtual extent metadata agree across text scales
  and retained window boundaries; scrolling produces no overlapping headings,
  clipped labels, or gaps caused by stale extent values.
- Both date parts remain readable at supported narrow widths and enlarged text;
  native header actions and the reserved sync region do not overlap the title.
- Dates and weekdays are correct at calendar boundaries and are announced once
  in a meaningful order. Missing calendar data remains truthfully unavailable.
- The implementation adds no compatibility path, divider, storage migration, or
  unauthorized changes to spec, dune, or bonsai_flutter OCaml files.

## Consequences

- Default tracking, font-dependent numeral widths, and centered weekday alignment
  differ from the original reference. These are accepted scope reductions and
  must not be reported as exact reproduction of the original typography.
- Larger text increases the two-line title height and can exhaust title width
  when both actions are present. Default-scale arithmetic alone is insufficient
  evidence of native layout correctness.
- Fixed low weekday opacity may be too weak for some themes or contrast modes;
  inspect actual rendering and increase contrast when required.
- Empty-day compaction introduces neighbor-sensitive geometry. A view-only
  padding change can leave the virtual list's extents inconsistent.
- The working tree contains existing header, calendar, Application, and timeline
  changes. Implementation must integrate with their current content and preserve
  unrelated work; preparing this proposal changes only this document.

## Questions

None. On 2026-09-06, the user answered Q1 by selecting only the portions currently
supported by bonsai_flutter. Custom letter spacing, tabular figures, and exact
alphabetic baseline alignment are excluded. The scope decision is resolved; the
other values above remain the first-iteration defaults from the supplied design.
