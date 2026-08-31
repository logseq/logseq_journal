# Long Row Metadata Tail Fade

## Problem

The physical-iPhone QuickTime review of a collapsed journal row with a
three-line title and two supporting child lines exposed three visual defects:

- the timestamp and disclosure affordance are vertically centered across the
  full five-line row instead of aligning with the first title line;
- Flutter's built-in multi-line `TextOverflow.fade` applies a vertical fade to
  the bottom edge of the paragraph, dimming the full last title line rather
  than only its trailing edge;
- the title and supporting preview touch with no separation, so the faded title
  and lower-contrast child text read as one paragraph.

The fixed metadata column also reserves horizontal space for every text line.
This is acceptable for predictable list geometry, but centering it through the
row makes the reserved column visually intrusive.

## Proposal

Adopt the implementation decision below and validate it through the complete
automated suite plus the required physical-iPhone QuickTime review.

## Decision

Keep the existing independent three-line title and two-line collapsed-child
budgets, while changing their presentation as follows:

- wrap the timestamp and optional disclosure indicator in a row-height metadata
  container aligned to the logical top trailing edge;
- insert one 4 logical-pixel gap between a title and its first supporting child
  preview and include that gap in sparse-list extent calculations;
- replace built-in paragraph fade with clipping plus an app-local native widget
  extension that overlays a theme-surface gradient only on the trailing edge of
  the final visible line when the OCaml preview measurement reports overflow;
- apply the same tail-fade primitive to direct child-preview rows so the
  truncation language remains consistent;
- retain one parent semantics node containing the complete source and visible
  supporting text.

The native extension is implemented inside this repository. It does not modify
the bonsai_flutter repository or its OCaml specification.

## Alternatives considered

### Keep Flutter `TextOverflow.fade`

Rejected because Flutter intentionally chooses a vertical bottom-edge gradient
when height or `maxLines` overflows. The observed whole-line dimming is therefore
expected framework behavior, not a parameter that can be corrected in OCaml.

### Manually split text into three one-line widgets

Rejected because application-side character-width estimates cannot reproduce
Flutter line breaking for all fonts, locales, grapheme clusters, emoji
sequences, and nonlinear text scaling. It would trade one visual defect for
incorrect wrapping.

### Add ShaderMask and flex-alignment primitives to bonsai_flutter

Rejected for this bugfix because the project explicitly forbids changing OCaml
files in the bonsai_flutter repository. An app-local native widget is sufficient
and keeps the change scoped to Logseq Journal.

### Clip without any fade

Rejected because it would remove the requested visual indication that more
content exists.

## Acceptance criteria

- A one-line row keeps its current compact height and timestamp placement.
- A three-title-line plus two-child-line row aligns timestamp and disclosure to
  the first title line in both LTR and RTL layouts.
- A 4-pixel gap separates title and supporting previews, and sparse extents
  include the gap without clipping or overlap.
- Latin, CJK, emoji, explicit-newline, and omitted-additional-child overflow
  states use a trailing-edge fade on only the final visible line.
- Supporting text remains smaller and at 65 percent opacity without an
  additional full-line vertical fade.
- Focused OCaml tests, Flutter widget tests, the complete Dune suite, Flutter
  analysis, and Flutter tests pass.
- A debug-profile build is installed and launched on the physical iPhone, and
  the corrected long row is inspected through QuickTime Player.

## Risks

- The fade decision uses the same conservative OCaml width estimator that owns
  sparse extents. A near-boundary string can be marked as overflowing one glyph
  earlier than Flutter's renderer, but it cannot escape its line budget.
- The gradient uses the active Flutter scaffold surface color. If a future row
  gains a distinct opaque surface, that surface color must become a native
  widget property.
- The fixed metadata column continues to reserve width on all visible lines to
  preserve deterministic sparse-list geometry.

## Questions

- None.

## Consequences

- Journal row text uses Flutter clipping for layout and delegates only the
  final-line trailing gradient to native widget kind 1001.
- The application host owns a stable widget registry that contains all core
  bonsai_flutter native widgets plus the Journal tail-fade extension.
- Collapsed rows with supporting previews are four logical pixels taller, and
  the sparse extent model publishes the same height before rendering.
- Physical-iPhone debug verification through QuickTime Player confirms that the
  timestamp and disclosure align with the first title line, title and child
  previews are separated, and only the final visible text tail fades.
