# Capture Doing Icon Task Toggle

## Problem

The Capture task toggle currently uses checkbox-shaped icons: an empty checkbox
when task intent is off and `task_alt` when it is on. This vocabulary differs
from the current timeline `Doing` status icon and makes the compact Capture
control look like a checkbox rather than a task-state action.

## Proposal

Render the Capture task toggle with the same `Timelapse` Material icon used by
the current timeline `Doing` action in both states. Preserve the existing
state-dependent button presentation: `Plain` with the `off` tooltip when task
intent is disabled, and `Filled` with the `on` tooltip when it is enabled.

Only the Capture toggle glyph changes. Its binary `No_status`/`Todo` behavior,
button ID, position, availability, persistence, and saving gate remain
unchanged.

## Decision

Adopt `Timelapse` as the single Capture task-toggle glyph. Continue using the
existing `Plain`/`Filled` button style and state-aware tooltip to distinguish
off from on. Remove the now-unused `Check_box_outline_blank` and `Task_alt`
catalog roles instead of retaining obsolete aliases.

## Alternatives considered

### Alternative

Use two different progress icons for off and on. This was not selected because
the request is to reuse the current `Doing` icon; the existing plain/filled
button treatment already communicates the toggle state without changing the
glyph.

## Acceptance criteria

- Capture renders Flutter `Icons.timelapse` at U+E660 while task intent is off.
- Capture continues to render the same `timelapse` icon after task intent is
  enabled.
- Off remains visibly `Plain` and announces `Capture as task, off`; on remains
  visibly `Filled` and announces `Capture as task, on`.
- Capture still persists `No_status` when off and `Todo` when on, and saving
  still disables interaction without changing the selected presentation.
- Focused and related tests pass.

## Risks

- A shared glyph places responsibility for communicating selection on the
  button fill and accessible tooltip. This is intentional and is guarded by
  behavior tests for both states.

## Questions

- None. The requested icon and the existing enabled/disabled presentation
  establish the intended behavior.

## Implementation evidence

The RED test rendered the off state as U+E158 and failed against the requested
U+E660. After the change, the application view test renders U+E660 in both off
and on states while continuing to assert `Plain`/`Filled`, the state-aware
tooltips, persistence, and saving-time interaction gating.

The focused application view test, full OCaml test suite, source-boundary and
Material icon artifact checks, debug native artifact build, Flutter test suite,
Flutter analysis, formatting check, and diff whitespace check pass.

## Consequences

- Capture now visually matches the timeline's current `Doing` icon.
- Selection remains distinguishable through the button fill and accessible
  tooltip rather than through two unrelated glyphs.
- The old Capture-only checkbox and task-alt catalog roles no longer exist.
