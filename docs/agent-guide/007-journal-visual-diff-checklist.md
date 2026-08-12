# Journal Visual Diff Checklist

Status: Implemented. Physical-device and assistive-technology release evidence remains open.

Date: 2026-08-10

Related:

- `docs/agent-guide/006-journal-reference-alignment.md`
- `docs/agent-guide/006-journal-reference-alignment_acceptance_report.md`

## Objective

Track the remaining style differences between the current macOS application screenshot and the approved mobile reference so that later UI work can be verified item by item without expanding product scope.

This checklist compares visual hierarchy, spacing, typography, alignment, color, component shape, and overlay behavior. It does not require feature parity with the reference.

## Comparison evidence

| Image | Local source | Dimensions | SHA-256 |
| --- | --- | --- | --- |
| Approved target reference | [Open target PNG](assets/007-journal-visual-diff/approved-target-reference.png) | `941 x 1672` | `52736e9506a43de70f24c653652eb6ee7c2d6823da700d74c3f09fa72e66a8e9` |
| Current macOS application | [Open current PNG](assets/007-journal-visual-diff/current-macos-application.png) | `870 x 1406` | `86c41a40f373a38e36f39bd3b6fa8272fef7345017bdf02a1a49e92e7865f8cb` |
| Implemented real-runtime golden | [Open implemented PNG](assets/007-journal-visual-diff/implemented-runtime-golden.png) | `390 x 844` | `fc55e0d12dd2a7e9703107791face28d97a7260ca641975c72d5e87146ba2306` |
| Leading-aligned normalized overlay | [Open leading overlay](assets/007-journal-visual-diff/overlay-leading.png) | `471 x 844` | `9a04709f2654336cce5baaa1de1b93764b5b4e8dab40e47f6c519af0f6813899` |
| Trailing-aligned normalized overlay | [Open trailing overlay](assets/007-journal-visual-diff/overlay-trailing.png) | `471 x 844` | `7b709017531ddf25f1ec34ab40a24fd6bdc229a4f9499b6750d4c5276c880eb0` |

The comparison excludes the macOS title bar and the target image's iOS status bar and home indicator. Horizontal observations must be normalized for the different viewport widths. Minor platform font rasterization differences are not defects by themselves.

The implemented golden uses the deterministic real OCaml runtime fixture. The approved target was uniformly resized to `471 x 836` and placed on a `471 x 844` neutral canvas. The `390 x 844` implementation was aligned separately to the logical leading and trailing edges. No nonuniform scaling was used.

## Implementation evidence

- `test/journal_adaptive_test.ml` verifies light, dark, and high-contrast palettes; typography; visual and semantic sizes; `1x` through `4x` physical dividers; and row profiles at text scales `1.0`, `1.3`, `2.0`, and `3.2`.
- `test/journal_semantics_test.ml` verifies normal, Todo, Done, parent, long-source, multi-digit child-count, compact, adaptive, LTR, and RTL row anatomy. It keeps task, disclosure, row-open, and Capture actions distinct.
- `test/application_view_test.ml` verifies independently centered Header composition, logical side-shell insets, palette surfaces, circular Capture geometry, shadow layers, overlay positioning, safe-area ownership, and deferred-action omissions.
- `flutter/test/journal_runtime_golden_test.dart` verifies real rendered centers and x-positions, inline parent metadata, typography, one-line ellipsis, the `44`-pixel Capture visual, the independent `56`-pixel semantic target, initial time occlusion, final-row reachability, and the checked-in golden.
- Manual review of both normalized overlays confirmed the corrected hierarchy, `48`-pixel row rhythm, source/task leading positions, trailing time reserve, Header shell placement, and circular Capture treatment. Expected ghosting remains for excluded fixture content, Search/status/home chrome, and the implementation's required bottom-safe-area clearance.

Repository verification completed with `opam exec -- dune runtest`, the full wrapped Flutter host suite, the opt-in real-runtime golden without update mode, `flutter analyze --no-pub`, `bonsai-flutter sync-host --check`, and `git diff --check`.

Physical iPhone portrait and landscape review, VoiceOver, Full Keyboard Access, IME, and other assistive-technology evidence remain release limitations. No pass is inferred for those environments.

## Scope exclusions

The following reference differences are feature or fixture differences and are not checklist failures:

- Search visibility or behavior.
- Date-selection chevron or interaction.
- Menu and More behavior.
- Styled hashtag or mention pills.
- Attachment thumbnails.
- The exact entry text, timestamps, dates, and number of rows.
- Missing older-day headings when the current store contains only one day.
- iOS and macOS system chrome.

## P0 layout and component checks

### Row vertical alignment

- [x] Align source text, inline metadata, disclosure, and the time column to one visual row center or baseline.
- [x] Remove the observed source-text top bias of approximately `20–25` screenshot pixels relative to the time column.
- [x] Verify normal, parent, Todo, and Done rows independently.
- [x] Verify alignment at text scales `1.0`, `1.3`, `2.0`, and `3.2` without forcing incompatible profiles onto one baseline.

Acceptance evidence: comparable screenshots plus geometry assertions for source, disclosure, and time positions.

### Time column

- [x] Move the time column inward from the trailing window edge to match the reference's reserved trailing space.
- [x] Keep one stable trailing column across normal, task, and parent rows.
- [x] Prevent source, disclosure, badges, and the FAB from colliding with or obscuring the time column.
- [x] Verify LTR and RTL logical placement.

Acceptance evidence: normalized leading- and trailing-aligned overlays and narrow-width geometry tests.

### Row dividers

- [x] Make the subtle inset divider visible between populated rows.
- [x] Match the reference's light visual weight without turning the feed into a high-contrast table.
- [x] Preserve a one-physical-pixel result across device pixel ratios.
- [x] Verify light, dark, and high-contrast palettes.

Acceptance evidence: pixel sampling or golden coverage at multiple device pixel ratios.

### Task-row indentation

- [x] Move Todo and Done indicators toward the ordinary content-leading edge.
- [x] Reduce the excessive gap between the task indicator and source text.
- [x] Keep task source text aligned with the reference while preserving a distinct task action target.
- [x] Confirm that non-task rows do not acquire a task placeholder.

Acceptance evidence: comparative x-position assertions for non-task, Todo, and Done rows.

### Task indicator scale and weight

- [x] Reduce the Todo ring and Done circle to the reference's visual scale.
- [x] Reduce Todo outline weight.
- [x] Reduce the white Done check's size and stroke weight.
- [x] Preserve the independent minimum semantic target even when the visual indicator becomes smaller.

Acceptance evidence: visual-node bounds, semantic target bounds, and golden review.

### Parent disclosure and child-count metadata

- [x] Place the disclosure and count badge directly after the visible source rather than floating near the time column.
- [x] Use a right-pointing disclosure for a collapsed LTR parent and a down-pointing disclosure only when expanded.
- [x] Keep the count badge compact and softly rounded rather than visually circular and oversized.
- [x] Preserve distinct row-opening and disclosure actions.
- [x] Verify long source truncation without losing the disclosure, badge, or time column.

Acceptance evidence: collapsed and expanded screenshots, semantic-state assertions, and long-source layout tests. Exact inline placement remains subject to the public structured-inline capability gate recorded in `006`.

### Capture FAB shape and occlusion

- [x] Render the dark FAB visual as a true circle rather than a vertical capsule.
- [x] Remove the conspicuous pale outer halo while preserving a separate invisible semantic target.
- [x] Match the reference's subtle elevation shadow.
- [x] Reduce and center the plus glyph within the dark visual circle.
- [x] Move the FAB toward the logical trailing edge to match the reference inset.
- [x] Ensure the initially visible final row and its timestamp are not obscured by the FAB.
- [x] Preserve last-row scroll clearance, bottom safe-area clearance, and RTL mirroring.

Acceptance evidence: visual bounds, initial-viewport occlusion assertion, last-row reachability assertion, and LTR or RTL golden coverage.

## P1 hierarchy and styling checks

### Body typography

- [x] Reduce source-text size toward the reference hierarchy.
- [x] Reduce source-text weight from the current heavy appearance toward Regular or Medium.
- [x] Keep primary text readable without relying on excessive weight.
- [x] Preserve one-line ellipsis and full-source semantics.

Acceptance evidence: font token assertions and normalized screenshot review.

### Header typography

- [x] Reduce the Today title size and weight while retaining clear hierarchy over the subtitle.
- [x] Rebalance the title, subtitle, and body-text size ratios.
- [x] Keep the title group independently centered.
- [x] Verify long localized subtitles without shifting the title group.

Acceptance evidence: header token assertions and compact or long-locale screenshots.

### Header spacing

- [x] Increase breathing space within the header so the title stack does not feel compressed.
- [x] Preserve clear spacing between Today, the subtitle, the indicator, and the bottom divider.
- [x] Keep the first timeline row vertically centered immediately after the header without reintroducing a second top safe-area inset.

Acceptance evidence: header child-position assertions and the existing no-double-safe-area regression test.

### Header side-shell positions

- [x] Move Menu toward the logical leading edge.
- [x] Move More toward the logical trailing edge.
- [x] Keep the date stack centered independently from the asymmetric side shells.
- [x] Verify mirrored placement under RTL.

Acceptance evidence: normalized x-position assertions at compact and wide widths.

### Header icon and surface weight

- [x] Reduce the Menu glyph's stroke weight and visual dominance.
- [x] Lighten the More circular surface and reduce any excess visual size.
- [x] Keep both shells nonactionable until a separate product contract activates their behavior.

Acceptance evidence: golden review plus negative semantics and handler assertions.

### Header divider

- [x] Make the full-width header bottom divider perceptible at the intended subtle contrast.
- [x] Distinguish the header from the Timeline through the divider rather than a strong background band.
- [x] Preserve one-physical-pixel rendering across device pixel ratios.

Acceptance evidence: palette tests and pixel-level golden review.

### Color hierarchy

- [x] Reduce the combined darkness and weight of primary text if typography changes alone do not match the reference.
- [x] Preserve a softer muted-slate treatment for dates, times, and metadata.
- [x] Move the canvas toward the reference's neutral near-white instead of a visibly cool gray cast.
- [x] Verify contrast requirements in light, dark, and high-contrast modes.

Acceptance evidence: token contrast checks and sampled golden colors.

## P2 composition checks

### Feed density and rhythm

- [x] Preserve the approximately `48`-logical-pixel compact row rhythm.
- [x] Confirm that corrected vertical alignment, dividers, and inline metadata make the feed feel structured rather than sparse.
- [x] Avoid reducing row height merely to compensate for oversized typography.
- [x] Verify a fixture containing normal, parent, Todo, Done, long-source, and final-row variants.

Acceptance evidence: the deterministic reference fixture and normalized overlay review.

### Background and elevation

- [x] Use one neutral near-white canvas hierarchy across Header and Timeline.
- [x] Avoid a visible background seam where the header divider should provide the boundary.
- [x] Express FAB elevation with a soft shadow rather than a large pale disc.

Acceptance evidence: background pixel sampling and golden review.

## Fixture-dependent checks

These items cannot be evaluated from the current screenshot and require a deterministic visual fixture before they can be checked:

- [x] Older-day heading typography, spacing, and color.
- [x] Long-source ellipsis beside disclosure and time metadata.
- [x] Emoji baseline and fallback-font alignment.
- [x] Multiple child-count widths.
- [x] Final-row clearance with enough content to scroll.
- [x] Confirm tag, mention, and attachment styling remain inactive because their separate product and framework gates are not activated.

## Completion rule

No checklist item may be marked complete from code inspection alone. Each completed item requires automated geometry or token evidence where practical and a manually reviewed screenshot at a comparable viewport. The final review must repeat the normalized overlay against the approved target without nonuniform scaling.

Closing this checklist does not activate excluded features and does not replace physical iPhone or assistive-technology acceptance.
