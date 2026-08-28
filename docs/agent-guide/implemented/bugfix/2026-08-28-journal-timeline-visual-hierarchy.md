# Journal Timeline Visual Hierarchy

## Problem

The Journal timeline does not communicate the hierarchy between a historical
day heading and the entries that belong to that day strongly enough. Mixed
Chinese and Latin content can also render with visibly different weight and
glyph scale, and at least one first-screen presentation appears to place
content underneath the top navigation area.

The implementation review found four separate causes or constraints.

### Day headings reuse a supporting-text role

`Journal_timeline.day_heading` renders historical day labels with
`typography.supporting`. The same token is used for child previews,
continuations, empty/loading messages, and secondary entry lines. At the
Balanced preset this is `14/20 Normal`, while a primary entry is `16/22
Normal`. The two roles inherit the same foreground color. The size difference
is therefore small, the date has no distinct weight, and color does not
reinforce the hierarchy.

The implementation does not actually make primary entries Bold: all three
presets define entry text as Normal (`400`). The reported all-bold appearance
must therefore be assessed at the resolved-font level rather than by changing
the entry token from an already-Regular value.

### Slot extents do not encode group rhythm

The varied-extent timeline stores `Day_heading` and `Top_level` as adjacent
slots. Today intentionally has no duplicate day-heading slot. At width 390 and
text scale 1, a historical heading is 36 points high and a one-line entry is
44 points high. `day_heading` centers a 20-point line in its slot, while an
entry uses eight points of top and bottom padding. There is no semantic token
for either the gap before a new day or the gap after its heading.

Consequently, the transition from the last entry of one day into the next day
is not materially stronger than the rhythm between two entries in the same
day. Increasing all heading padding symmetrically would also weaken ownership:
the heading needs more space above it and less space between it and its first
entry.

Multi-line entry extents use `16 + line_count * block_line_height`. The
44-point minimum is required for rows that can disclose children, but the
additional eight-point top and bottom visual padding is not required for
multi-line rows. Same-day density can improve without shrinking any interactive
target below 44 points.

### The top inset is already split between Flutter and the application

`application.ml` forwards `environment.safe_area.top` to
`Journal_header.sliver`. The application uses it to position the subtitle in
the custom flexible space, while the native `SliverAppBar` remains `primary`
and separately adds `MediaQuery.padding.top` to its rendered extent. The
configured scale-1 extents intentionally exclude the safe area: they are 97
points expanded and 57 points collapsed at DPR 1, while the runtime test with
a 47-point top inset expects rendered extents of 144 and 104 points.

This means adding a root `SafeArea` or adding `top_inset` to the configured
sliver heights would double the inset. Existing runtime coverage proves the
static Balanced expanded/collapsed geometry, but it does not prove the
first-frame bounds for every typography preset after a Settings route closes
or after preset-dependent sparse extents change. The checked-in Comfortable
golden also shows the title at the top edge rather than at the position seen in
the Balanced and Dense goldens. That artifact must be reproduced against the
current runtime before deciding whether the defect belongs to scroll-position
restoration, a preset update, or header layout.

### The current font chain is Latin-first and platform-inconsistent

`application_theme` does not pass `font_family` or
`font_family_fallback` to `Ui.Theme.Typography.material`. In the installed
renderer, `_decodeTypography` starts from `Typography.material2021().black`.
Flutter's default argument selects the Android typography baseline, whose
roles use `Roboto`, even when the host is iOS or macOS. The project declares no
application text fonts in `flutter/pubspec.yaml`; runtime Chinese glyphs must
therefore fall through from Roboto to an installed CJK family. Latin letters
and digits and Chinese characters in the same entry are not guaranteed to use
the same family, glyph scale, or real weight face.

The public theme API already supports one `font_family` and an ordered
`font_family_fallback`, so this part does not require a renderer protocol
change. Per-widget `Text_style`, however, cannot select a semantic Material
color. The implemented seed-owned styling decision also forbids introducing a
new fixed date color or opacity approximation merely to imitate
`onSurfaceVariant`.

## Proposal

Treat this as one timeline hierarchy correction with four implementation parts
and one explicit color deferral. Do not change journal data grouping, date
formatting, timeline order, or the rule that Today has no duplicate heading.

### Give historical dates a dedicated typography role

Add `day_heading` to the preset-dependent typography contract instead of
reusing `supporting`.

| Preset | Day heading | Primary entry | Supporting text |
| --- | --- | --- | --- |
| Dense | `13/18 SemiBold` | `15/20 Normal` | `14/20 Normal` |
| Balanced | `13/18 SemiBold` | `16/22 Normal` | `14/20 Normal` |
| Comfortable | `14/20 SemiBold` | `17/24 Normal` | `15/22 Normal` |

Keep primary entries Normal. The date is smaller than the entry but uses
SemiBold to remain scannable as a group label. Supporting lines and child
previews remain Regular and no longer implicitly define heading presentation.

### Encode asymmetric day-group spacing

Introduce explicit geometry for a 20-point gap before a historical day label,
a four-point gap after the label, and six points of visual top and bottom
padding for entry rows. Derive the known sparse extents from those values and
the active scaled line heights:

```text
day_heading_extent = 20 + scaled_day_heading_line_height + 4
entry_extent = max(44, 12 + visible_lines * scaled_entry_line_height)
```

Position the day label toward the bottom of its slot instead of centering it.
This makes the boundary above the label visibly larger and keeps the label
attached to the first entry below. At scale 1, the historical heading becomes
42 points in Dense and Balanced and 44 points in Comfortable. A one-line row
remains 44 points in every preset. Balanced two-, three-, and four-line rows
become 56, 78, and 100 points instead of 60, 82, and 104.

The row's rendered padding and `Journal_timeline_state.extent_geometry` must
consume the same geometry values. Do not create decorative spacer rows, add a
divider, or make virtual extents depend on post-render measurement.

### Use one Apple system family for mixed-script journal text

For the current iOS/macOS-only host, set the application typography's primary
family to `PingFang SC`, with `CupertinoSystemText` and `Apple Color Emoji` as
fallbacks. This makes Chinese, Latin letters, and digits resolve through one
family whenever PingFang supplies the glyph, while retaining an Apple system
fallback and emoji coverage. It adds no font asset or application-size cost.

Apply the family at `Ui.Theme.Typography.material` so Material components and
application-owned text share the same chain. Do not add family fields to every
text token. Add a mixed Chinese/English/digit fixture because the existing
goldens contain English only and load only Roboto Regular plus Material Icons
and Apple Color Emoji.

This selection is intentionally Apple-specific. A future non-Apple host must
replace it with a separately selected bundled cross-platform family rather
than silently falling back to Roboto.

### Defer subdued date color

The intended historical-date foreground is Material `onSurfaceVariant` in
normal light and dark themes, with the renderer's corresponding high-contrast
resolution. Do not encode an ARGB value, reuse a status-rail color, or apply
opacity to inherited text.

The current generic text protocol cannot name a semantic color. Complete color
de-emphasis therefore requires a published `bonsai_flutter` capability that
lets application-owned text request a renderer-resolved semantic color, then a
normal dependency refresh in this repository. Do not patch generated
`.bonsai-flutter` sources or modify the `bonsai_flutter` repository as part of
this application change.

The user selected an application-only first change on 2026-08-28. Ship the
typography, spacing, font, and clipping corrections while leaving the date
foreground inherited. Semantic color de-emphasis remains out of scope until a
separate framework capability is available; do not add a fixed-color exception
or make that future capability a prerequisite for this work.

### Verify clipping as a scroll/header lifecycle bug

Retain one vertical custom scroll view and the native `SliverAppBar` ownership
of the top safe area. Add runtime assertions for each typography preset at
scroll offset zero, with 47-point top and 34-point bottom insets, both on initial
mount and after opening Settings, changing the preset, and closing Settings.
The title and Account action must remain below the top inset, the expanded
subtitle must be hit-testable, and the first timeline slot must begin at or
below the app-bar paint boundary.

Also exercise collapse and return-to-top after the preset change. If the test
reproduces clipping, fix the scroll-position or header-rebuild lifecycle that
causes the nonzero/collapsed presentation. Do not add another safe area. Update
the typography goldens only after the bounds assertions pass.

## Decision

- Add a dedicated `day_heading` typography token with `13/18 SemiBold` metrics
  for Dense and Balanced and `14/20 SemiBold` for Comfortable. Keep entry and
  supporting roles at Normal weight.
- Add explicit 20-point before-heading, four-point after-heading, and six-point
  entry vertical-padding geometry. Derive rendered padding and sparse extents
  from the same tokens, with a 44-point minimum interactive row extent.
- Publish `PingFang SC` once through the application Material typography, with
  `CupertinoSystemText` and `Apple Color Emoji` fallbacks. Do not add per-widget
  family overrides or bundled application font assets.
- Preserve the native `SliverAppBar` as the sole owner of the top safe area.
  Verify initial, collapsed, Settings-change, and return-to-top bounds instead
  of adding another inset.
- Continue inheriting the active theme foreground for historical dates. Defer
  semantic `onSurfaceVariant` color until bonsai_flutter exposes a renderer-
  resolved semantic text-color capability.

## Alternatives considered

### Make the date larger or bolder than entry content

This would make group boundaries obvious, but it would invert the requested
hierarchy and cause every historical date to compete with the journal content.
A smaller SemiBold label plus spacing is easier to scan without becoming the
primary reading target.

### Keep symmetric heading padding

Increasing both sides of a centered date adds whitespace but does not clarify
ownership. The heading remains equally detached from the previous and next
groups. Asymmetric spacing directly encodes the relationship.

### Add a divider between date groups

A divider would make boundaries explicit, but it adds visual noise to a text
feed and is unnecessary once spacing and heading treatment establish the
group. It would also spend part of the project-wide three-divider budget.

### Add a second SafeArea around the Journal body

The native sliver already consumes the top `MediaQuery` padding. A second safe
area would double the top inset in the normal case and would conceal rather
than diagnose any scroll-restoration defect.

### Use a fixed or translucent date color in the application

This is implementable through `Style.Text_style.create ~color`, but it creates
a second color authority, does not adapt through Material's dynamic/high-
contrast scheme, and conflicts with the implemented seed-owned styling
decision. It is not selected.

### Keep Roboto with a Chinese fallback

Adding only `PingFang SC` to `font_family_fallback` would document the existing
fallback but preserve the mixed-family line that caused the feedback. Making
PingFang the primary family is the smallest current-platform correction.

### Bundle a cross-platform CJK family

Bundling a family such as Noto Sans CJK SC would make rendering deterministic
across Apple and future platforms. It would also add font assets, application
size, licensing attribution, weight-file selection, and new golden setup. It
is preferable if non-Apple support is imminent, but it is not the default for
the repository's current iOS/macOS host.

## Acceptance criteria

- Historical dates use the dedicated preset metrics documented above and no
  longer consume `typography.supporting`.
- Primary entry and supporting text remain Normal weight in every preset.
- At scale 1, historical day slots provide 20 points before the label and four
  points after it; entry content uses six-point vertical padding while every
  interactive row remains at least 44 points high.
- `Journal_timeline_state` publishes exact sparse extents derived from the same
  typography and spacing values used by rendered headings and rows.
- The transition between different dates is visibly larger than the rhythm
  between same-day entries, and a date is visually closer to its following
  entry than to the preceding group.
- The application theme publishes the selected primary and fallback font
  families once. A runtime mixed-script fixture containing Chinese, English,
  and digits resolves to one coherent family and preserves the requested
  Regular/SemiBold role weights on iOS and macOS.
- Historical dates continue to inherit the active theme foreground in light,
  dark, high-contrast light, and high-contrast dark modes. No concrete
  application color, opacity-based substitute, or `bonsai_flutter` semantic-
  color prerequisite is introduced by this change.
- With top inset 47 and bottom inset 34, every typography preset starts below
  the unsafe region on initial mount and after a Settings preset change. The
  expanded and collapsed app bar retain correct paint extents and returning to
  scroll offset zero fully reveals the header and first timeline slot.
- Mixed-script, multi-day runtime goldens cover Dense, Balanced, and
  Comfortable at `390 x 844`. Bounds assertions accompany the images so a
  clipped header cannot be approved as a new golden.
- Widths 320, 390, 744, and 1200 at text scales 1.0, 1.3, 2.0, and 3.2 retain
  readable headings, exact virtual extents, stable logical scroll anchors,
  RTL alignment, and no lost row content.
- No screen gains a divider, and the rendered divider count remains at most
  three.
- No Dune file, OCaml file under `spec/`, generated `.bonsai-flutter` source,
  or OCaml file in the `bonsai_flutter` repository is modified.

## Implementation evidence

- Token and sparse-list tests verify all three day-heading roles, 20/4 group
  spacing, six-point entry padding, exact one-to-four-line extents, the 44-point
  minimum, and the complete 320/390/744/1200 width by 1.0/1.3/2.0/3.2 scale
  matrix.
- Application view tests verify that historical dates use the dedicated
  SemiBold role and asymmetric padding while retaining no explicit color. Theme
  wire tests verify the single `PingFang SC`, `CupertinoSystemText`, and
  `Apple Color Emoji` chain for normal and high-contrast light and dark data.
- The real runtime fixture contains Chinese, English, digits, a historical day,
  and multiline entries. Dense, Balanced, and Comfortable goldens at
  `390 x 844` show the corrected hierarchy; all affected capture, reference,
  swipe, dark, high-contrast, and RTL goldens were regenerated through
  `bonsai-flutter exec` and visually inspected.
- Runtime assertions prove that a 47-point top inset remains owned once, the
  title and Account action remain below it, the expanded subtitle is
  hit-testable, and the first timeline slot begins after the app-bar paint
  boundary. Each preset also collapses and returns to offset zero after the
  Settings route closes.
- The reported top clipping did not reproduce after the bounds were made
  explicit, so no redundant SafeArea, height correction, or scroll-restoration
  mutation was added.
- `dune build @fmt`, `dune build @all`, `dune build @install`, `dune runtest`,
  and the five isolated real-runtime Flutter cases pass. The source-boundary
  suite confirms no forbidden Dune, specification, generated renderer, or
  bonsai_flutter repository edit.

## Consequences

- Historical dates now read as compact group labels instead of supporting copy,
  and their whitespace associates each label with the following entry group.
- Multiline rows are four points denser while one-line and interactive rows
  retain the 44-point minimum. Virtual and rendered geometry remain identical.
- Mixed Chinese and Latin application text resolves from one Apple-first theme
  family chain in production. Golden tests register a deterministic single-file
  mixed-script face under that production family name because Flutter's test
  `FontLoader` cannot select an individual face from the system PingFang TTC;
  protocol tests independently verify the published production family.
- Header safe-area ownership remains unchanged and is now protected by runtime
  paint-boundary assertions across preset changes.
- Historical dates still use the inherited foreground. A later semantic-color
  change requires a separate framework-backed decision and dependency update.

## Risks

- `PingFang SC` is an Apple platform family. Missing or renamed family behavior
  must fail visibly in runtime tests; it is not a cross-platform typography
  contract.
- Using PingFang for Latin text trades the familiar Roboto/Material Latin
  appearance for mixed-script consistency.
- SemiBold date text can regain too much visual prominence if semantic color
  de-emphasis is deferred. The multi-day golden must judge the combined result.
- Smaller multi-line extents increase density but reduce vertical breathing
  room by four points. Text-scale and child-disclosure tests must prove that
  text and hit regions do not clip.
- Changing known sparse extents can shift physical scroll offsets. Logical
  visible-slot anchoring must remain stable across preset changes and live feed
  updates.
- The first change intentionally does not lower the historical-date foreground
  brightness. If typography and spacing alone do not provide sufficient
  hierarchy, semantic color requires a later framework-backed decision.
- Fixing clipping without reproducing the reported lifecycle could add a
  redundant inset and regress the already-correct static safe-area geometry.

## Questions

None. On 2026-08-28, the user selected Apple system `PingFang SC` as the primary
family and selected an application-only first change that leaves historical-
date color inherited while implementing typography, spacing, font, and
clipping verification. That decision was implemented on 2026-08-28.
