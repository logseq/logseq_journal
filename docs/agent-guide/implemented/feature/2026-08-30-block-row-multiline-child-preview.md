# Block Row Multiline Child Preview

## Problem

Journal timeline rows render every source and child-summary fragment as a
single-line ellipsized `Text`. Long block titles therefore hide nearly all of
their content even when the row could use a small bounded amount of vertical
space. Collapsed parents currently share one four-logical-line budget between
their own source and child summaries, so the parent title can consume the whole
preview and the result does not express the requested three-line title plus
two-line child hierarchy.

The list's day headings also use 13--14 point type while the AppBar's `Today`
title uses 22--24 point type. The date hierarchy is consequently much weaker
than the current visual target.

The virtual timeline requires exact row extents before Flutter lays out the
materialized rows. Flutter does not report arbitrary measured text heights back
through the current sliver protocol, so multiline text needs a deterministic
width-aware line estimate that drives the same bounded row extent used by the
rendered text.

## Proposal

Render every top-level block source as one start-aligned `Text` with a maximum
of three lines and `Fade` overflow. Preserve embedded newlines and allow Flutter
to wrap long logical lines naturally. Remove the old per-logical-line widgets
and ellipsis behavior instead of retaining a compatibility path.

When a collapsed timeline entry has direct-child summaries, render at most two
additional child-summary lines after the title. Child summaries use the
existing smaller supporting typography and a 0.65 opacity wrapper. Allocate the
two-line budget in child order: a wrapping first child may consume both lines;
otherwise the next child may use the remaining line. Expanded parents omit
these inline summaries because their children already appear as separate child
preview rows.

Render expanded child preview titles with the same three-line, fade-overflow
limit. Keep their supporting typography and apply the same 0.65 opacity so the
visual hierarchy is consistent.

Add the available source-text width to the selected row profile. Estimate
wrapped line counts from bounded UTF-8 scalar widths, explicit newline breaks,
the selected font size, and that available width. Clamp top-level source lines
to three and inline child-summary lines to two. Use the resulting one-to-five
line count as the authoritative sparse-list extent and status-rail height. The
estimate is layout metadata only; displayed and semantic text remains the
complete original source.

Make every day-heading token use the same font size and line height as the
corresponding AppBar header-title token for Dense, Balanced, and Comfortable
presets. Keep the current semibold heading weight and recompute the fixed day
heading extent from the enlarged token.

## Decision

Implemented the proposal without compatibility paths. Top-level row titles are
single three-line `Text` widgets with fade overflow. Collapsed direct-child
summaries have an independent two-line budget, supporting typography, and 0.65
opacity. Expanded child previews use the same three-line fade limit and
subordinate treatment.

The selected row profile now owns its effective text scale, source width, and
entry/supporting font sizes. A bounded UTF-8 scalar-width estimator supplies the
authoritative one-to-five-line sparse extent before Flutter layout. Explicit
newlines and physical wrapping therefore affect the row, focus, and status-rail
extent consistently.

Day headings now match the corresponding header-title font size and line
height. The iPhone debug build also exposed a pre-existing cross-platform
compile failure in the test-file Keychain path; that macOS-only `SecKeychain`
code is now excluded from iOS while the shared debug in-memory test storage
remains available.

## Alternatives considered

### Reserve five lines for every top-level row

This guarantees room for every maximum-size preview without estimating text,
but creates large empty gaps for the common one-line row and materially reduces
timeline density.

### Replace the virtual timeline with a measured non-virtualized list

This would let Flutter derive intrinsic row heights, but removes the existing
bounded materialization and visible-range loading contract. That performance
and behavior change is outside this presentation request.

### Keep one-line child widgets and ellipses

This cannot show a wrapping title and contradicts the requested fade ending.
The obsolete rendering path will be removed.

## Acceptance criteria

- A long top-level block title wraps naturally and renders at most three lines.
- A title that still overflows its three-line limit ends with a fade and never
  an ellipsis.
- A collapsed parent renders no more than two additional direct-child summary
  lines, using smaller supporting type and 0.65 opacity.
- A title can use all three title lines without consuming the separate two-line
  child-summary budget.
- Expanded child preview titles render at most three faded lines and remain
  visually subordinate to top-level titles.
- Explicit newlines, long unbroken Latin text, CJK text, emoji, empty text, and
  text-scale changes produce bounded positive row extents without clipping the
  configured line budgets.
- Day-heading font size and line height equal the AppBar `Today` title for every
  typography preset, and the day-heading sparse extent grows accordingly.
- Semantics retain the complete source and the currently visible collapsed
  child summaries; fading does not alter accessible text.
- Focus, disclosure, swipe, sparse-window, RTL, and the no-more-than-three-
  dividers rule remain intact.
- Focused OCaml tests and the relevant Flutter tests pass.
- A debug-profile build runs on a connected physical iPhone and visual review
  through QuickTime Player confirms wrapping, child hierarchy, fade overflow,
  and date size.

## Risks

- Deterministic glyph-width estimation cannot exactly reproduce every font's
  shaping. The estimator is deliberately conservative and the physical-iPhone
  check is required to tune it so rendered text does not clip.
- Larger date headings and multiline rows reduce the number of entries visible
  at once; this is the intentional cost of the requested readability.
- The child-summary preview is bounded to direct children already supplied by
  the feed and does not perform additional graph reads.

## Consequences

- Short one-line rows retain the existing compact minimum extent, while rows
  grow only when the deterministic estimate requires more title or child lines.
- The sparse timeline remains virtualized and keeps its visible-range loading
  protocol; no intrinsic-height renderer extension was added.
- Long text now preserves more context without a trailing ellipsis, and
  accessibility retains complete normalized source text plus the summaries
  represented by the collapsed preview.
- OCaml focused and full suites, Flutter host tests and analysis, iOS Swift
  typechecking, macOS Keychain harness, signed iPhone debug launch, and
  QuickTime Player mirroring all validate the implemented decision.
