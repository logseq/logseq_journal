# Timeline Pull Stage Icons

## Problem

Timeline's two pull gesture stages currently show visible English text. The user
requested a down arrow before the threshold and a reload symbol once armed.

## Decision

Replace only the existing hint Text with a native SF Symbols Image: arrow.down
before the threshold and arrow.clockwise when armed. Retain the footnote type
scale, regular symbol weight, secondary tint and current top placement. A fixed
24-point display area keeps both stages centered without shifting List layout.
Keep English accessibility labels Pull to sync / Release to sync and the same
accessibility identifier. Do not animate the symbols. Leave thresholds, gestures,
events, reconnect/pull owners and the existing Options-left spinner unchanged.

PR115 is merged and current main is bfd603e. Implement on a new independent
branch. No protected spec/, Dune or diagnostics-owner workspace changes.

## Alternatives considered

### Rotating reload symbol or a new refresh indicator

Rejected: the armed symbol is a static release affordance. Actual sync activity
continues to use the existing header spinner and shared state.

## Acceptance criteria

- Actual native drag shows arrow.down, then arrow.clockwise, with English AX
  labels; release/cancel removes the hint and only the existing spinner runs.
- Threshold, duplicate trigger, List/row identity and content anchors are unchanged.
- Use existing checks and temporary native acceptance; no redundant permanent tests.
- Coordinate GUI and compiler resources before native acceptance. Do not touch the
  protected A135/1446 real app containers, reset devices or create another device.
- Preserve ABI boundaries. Prefer a fresh pure-Swift fixture of the real List for
  this Swift-only visual change rather than loading old cross-platform OCaml code.
- Record a short actual Simulator video and create a non-Draft PR; do not merge.

## Consequences

- A coordinated A135 window was used for a distinct-bundle pure-Swift fixture of
  the actual production List and Chrome views, using synthetic content and native
  XCTest drags. One acceptance test passed: below-threshold cancellation, release
  once, repeated gestures, the sole existing header spinner and stable row anchor
  and Options position. The recording shows both symbols and simulated completion.
- Armed English accessibility was observed in the native hierarchy; both English
  labels remain explicit in source. Continuous down-then-up while keeping the
  finger held was not separately exercised by the straight-segment XCTest driver.
- The fixture does not validate live sync, JournalRuntime or OCaml ABI. Existing
  shared-sync recovery (27) and worker-presentation (6) baseline tests passed;
  application and sync-owner source are unchanged.
- The distinct fixture was stopped and the original Journal process restored.
  Real containers, accounts, graph data, network settings and device state were
  preserved. No permanent test target was added.

## Questions

None for implementation: the user selected both symbols and authorized the PR.
Device/resource coordination and native acceptance are complete.
