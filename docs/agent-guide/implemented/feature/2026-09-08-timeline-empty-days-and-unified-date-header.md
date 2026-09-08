# Timeline Empty Days and Unified Date Header

## Problem

The timeline displays date headings for journal pages with no blocks, or with
only a single block whose title is empty. These headings add visual noise without
useful journal content. The header also presents its date and weekday on separate
lines with different emphasis from the dates in the timeline.

The requested behavior is to hide those empty journal dates in the timeline and
show the header date and weekday on one line, using the same format, style, and
size as other timeline dates.

Pre-implementation evidence:

- `app/journal_timeline_state.ml` creates historical `Day_heading` slots in
  `day_slots` independently of whether the day has meaningful content. This owner
  also manages continuations, retained slots, counts, anchors, and heading extents.
- `app/journal_timeline.ml` renders historical dates as `YYYY.MM.DD` and uppercase
  English weekdays in one row, with a 14dp gap.
- `app/journal_header.ml` renders the current date above its weekday with a 2dp
  gap and computes toolbar geometry for that column.
- `app/journal_visual_tokens.ml` uses 24sp/w600 for the header date and 20sp/w400
  for timeline dates. Normal weekday opacity also differs: 0.55 versus 0.50.
- `Journal_model.source` exposes block text, and `Journal_model.child_count`
  exposes child presence. `Journal_graph_projection.page.title` is the journal
  page title, not the block title mentioned in this request.

## Proposal

### Hide empty journal sections

Treat a fully known journal day with zero top-level blocks as empty. Also hide a
day with exactly one top-level block only when all of these conditions hold:

- Its title is empty or contains only whitespace, as determined from block source
  without changing the stored text.
- Its `child_count` is zero.
- Its task state is `No_status`.

Keep the day visible if that block has children or any task status, even when its
title is empty. A visually empty formatted title with non-whitespace source does
not qualify. Do not extend the rule to multiple empty-title blocks without a
further decision: the request specifically describes zero blocks or one empty
block. The user confirmed both boundary rules on 2026-09-08.

Hide the complete empty timeline section, including its
date heading, lone placeholder row, and associated spacing. Do not leave an
unlabeled blank row or reserved gap. This is a presentation rule; retain the page
and block in the graph. It must remain possible for later content to make the day
visible again.

A partial page, an active continuation, or a failed request is not evidence of
emptiness. Keep loading and retry affordances reachable until the day is known
complete. Evaluate the full known day, not only the visible or retained fragment.
Keep feed pagination advancing by the fetched page boundary even when every day
in a batch is hidden, so older populated dates remain reachable.

Reevaluate visibility after feed refresh, day-page completion, block edits,
creation, deletion, undo, task-status changes, and relevant child-count updates.
A hidden day becomes visible when it gains qualifying content; removing its last qualifying content
hides it again. Preserve chronological ordering and stable keys for surviving
rows. Update slot counts, extents, neighboring spacing, and scroll anchors
together so filtering does not leave gaps or cause avoidable scroll jumps.

The top header continues to identify today even when today's journal is empty.
Today still has no duplicate date heading inside the list. Keep capture available
when every loaded day is empty.

### Match the header to timeline dates

Use the existing historical date presentation as the reference for both places:

```text
2026.09.08   TUE
```

The illustration represents a real 14dp layout gap, not literal padding spaces.
At default text scale, use the following shared date styles across typography
presets:

| Element | Format | Size / weight | Line height | Foreground |
| --- | --- | --- | --- | --- |
| Date | `YYYY.MM.DD` | 20sp / w400 | 24dp | Theme primary text |
| Weekday | Uppercase `MON` through `SUN` | 12sp / w500 | 14.4dp | Same theme text at 0.50 opacity; 0.85 in high contrast |

Center the weekday vertically within the date row. Retain the header's centered
placement and the timeline headings' content-leading placement; matching text
style does not require relocating the app-bar title. Use a coherent effective
date scale in both locations, accounting for native app-bar scaling and available
width. At supported enlarged text sizes, the header must not silently become a
different size from timeline dates. Preserve the existing single-line date
policy and leave body-text scaling independent.

Recalculate title and toolbar geometry for a single row. Preserve native account
and error actions, accessible hit targets, the pinned Material app bar, and its
stable 2dp sync-progress region. The Favorites title is outside this date-specific
change. Continue using structured `Journal_calendar.date_presentation` values,
truthful unavailable-date text, and a single readable date-and-weekday announcement.

This decision supersedes the two-line header, larger current-date emphasis,
and known-empty-heading spacing requirements in
[Timeline Date Typography Hierarchy](../../implemented/feature/2026-09-06-timeline-date-typography-hierarchy.md).
It does not alter date storage or calendar calculations. Remove obsolete date
rendering and geometry paths instead of retaining a compatibility mode; preserve
tokens still used by non-date titles.

### Ownership and verification approach

Use `Journal_timeline_state` as the first production ownership boundary to
investigate empty-day behavior. Attempt reproduction through its public request
and completion functions, block mutations, windows, and request observations
before adding regression tests. If that boundary reproduces a defect, add only
pure reducer regression coverage for it. Do not duplicate it in effect-runner,
persistence, transport, integration, E2E, or UI tests. If required completeness
information is missing, document the ownership gap and exercise only the
narrowest real boundary; injecting a prefiltered or already incorrect external
result is not a pure reproduction.

Implementation areas include `app/journal_timeline_state.ml/.mli`,
`app/journal_timeline.ml`, `app/journal_header.ml`,
`app/journal_visual_tokens.ml/.mli`, and their Application wiring as needed.
The ownership investigation and resulting changes are recorded below. Use public interfaces without
copying implementation logic or bypassing `.mli` boundaries.
Inspect rendered header and timeline typography to verify visual equality;
reducer assertions cannot establish visual layout correctness.

Follow `docs/ux-guidelines.md`: prefer built-in Flutter components, add no
dividers, keep the total at three or fewer, and preserve immediate reopening of
the most recently opened graph. Do not modify OCaml files under `spec/`, any dune
file, or OCaml files in the bonsai_flutter repository. If unclear or unreasonable
`spec/` interfaces block development, stop and report the exact issue, suggested
spec changes, and rationale.

The user requested transition to proposed on 2026-09-08 after resolving both
product questions. The user requested implementation on 2026-09-08; the completed behavior and
verification are recorded below.

## Decision

Implemented on 2026-09-08 following the user's explicit implementation request.

- `Journal_timeline_state` retains bounded day summaries alongside the existing
  retained slots: full fetched top-level counts, completeness, page identity, and
  at most one hidden placeholder per hidden day. Both slots and day summaries
  remain bounded by 512. Counts include evicted rows, so a retained fragment is
  never treated as the whole day. Filtering occurs before retention capping.
- Feed/day completions and public block mutations normalize entire sections and
  update virtual counts and visible anchors together. Hidden siblings return in
  source order; undo preserves intervening edits. Hiding an expanded parent also
  clears its expansion and child-request ownership. The feed continuation still
  uses the fetched page boundary, including batches consisting entirely of empty
  days. Existing Worker page/block interests remain registered independently of
  rendered slots, so hidden pages continue receiving reconciliation events.
- The public `Journal_model.create` boundary previously rejected blank source
  before a block could reach the reducer. Stored block validation now accepts
  empty and whitespace-only text without changing it, while retaining UTF-8,
  size, and NUL checks. Capture/edit submission validation still rejects blank
  input. Model tests cover this prerequisite at its actual ownership boundary;
  empty-section behavior is covered only through public pure timeline state APIs.
- `Journal_header.Date_row` is the shared renderer for both date locations. It
  uses the existing timeline typography and a 14dp gap. Its application-native
  adapter selects Flutter's built-in `Row(mainAxisSize: MainAxisSize.min)` because
  the framework's generic Row expands to the available width. No framework
  source change or custom layout algorithm is needed.
- A shared effective date scale reserves room for both native header actions,
  regardless of whether the error action is currently present. It compensates
  for native AppBar title scaling and leaves body scaling independent. At 320dp
  dates remain at their default single-line size; wider layouts permit enlarged
  dates equally in both locations. Favorites keeps its existing title typography,
  sizing, and toolbar geometry.
- Removed the date column, separate current/historical weekday-opacity modes,
  and empty-heading adjacency geometry. No graph records are removed and no
  compatibility renderer, spec edit, dune edit, or framework edit is introduced.

### Verification

The initial pure reducer test failed because a complete zero-block day produced
`day:20260808`. The renderer test failed because the actual header font size was
24sp while the historical date was 20sp. The model round-trip test separately
exposed the blank-source admission restriction. All were observed before their
respective implementation changes.

Verification completed:

- `dune build @all` and `dune runtest` passed, including the existing retention,
  persistent-update allocation, pagination recovery, geometry, and application
  suites. New pure state coverage exercises empty/whitespace sources, all task
  states, children, formatted sources, multiple placeholders, failed and partial
  requests, empty batches, mutations, undo, refresh, ordering, retained fragments,
  child-request release, and visible anchors.
- `bonsai-flutter build macos --profile=debug` passed and produced
  `flutter/build/macos/Build/Products/Debug/bonsai_flutter_logseq_journal_host.app`.
- `flutter analyze` passed with no issues. The default Flutter suite passed
  143 tests; seven existing opt-in real-runtime goldens were skipped because
  `RUN_REAL_OCAML_GOLDEN` was not enabled.
- 116 real OCaml-frame Flutter layout cases passed, including 48 header cases,
  48 combined header/timeline cases, and 20 existing Favorites cases. They check
  actual rendered font sizes, weights, line heights, foregrounds, opacity, 14dp
  gaps, centered weekdays, unclipped labels, semantics, native action hit targets,
  and the stable 2dp progress region. The date cases cover all typography presets,
  light/dark themes, high contrast, LTR/RTL, widths 320/390/720, and scales 1/3.2.
- Rendered PNGs were inspected for default typography, enlarged dates at 390/720dp,
  narrow RTL/high-contrast layout, and both native actions with active progress.
  Transient review artifacts are in `/tmp/journal-unified-date-visuals`.

## Alternatives considered

### Hide only the date text in the view

This leaves empty rows or heading extents in the virtual list and can separate
rendered geometry from state-owned geometry. Hide the empty section coherently.

### Filter graph records or stop pagination at an empty batch

Removing records would turn a display preference into data loss. Stopping at an
empty batch would make older populated days unreachable. Retain graph data and
the original pagination boundary.

### Keep a larger header date on a single line

This meets the line-layout request but still violates the requested matching
style and size. Use the timeline date style in both locations.

## Acceptance criteria

- A complete day with no blocks contributes no timeline heading or empty gap.
- A complete day with exactly one block whose title is empty or whitespace-only,
  whose child count is zero, and whose task state is `No_status` contributes no
  heading, placeholder row, or gap.
- A single empty-title block with children or any task status keeps its day
  visible. Changes to child count or task status reevaluate this rule.
- A day with a nonempty block remains visible. Days with multiple top-level
  blocks retain their current visibility under this narrowly scoped rule.
- Unknown, partially loaded, or failed days retain reachable loading/retry
  behavior. An empty feed batch does not prevent loading older populated days.
- Editing, creating, deleting, undoing, or refreshing content updates visibility
  consistently, including across retained-window boundaries, without stale
  extents or avoidable anchor jumps.
- The header remains visible for an empty today; capture remains available when
  the timeline has no populated days.
- Header and timeline dates use the same single-line format, date and weekday
  typography, gap, contrast behavior, and effective size. Header placement stays
  centered and historical headings retain their content-leading alignment.
- Visual inspection covers light/dark themes, high contrast, narrow widths, RTL,
  and enlarged text, including both header actions and active sync progress.
  Labels remain readable without clipping, overlap, or duplicate announcements.
- No graph data is deleted by filtering, and no compatibility renderer or
  unauthorized spec, dune, or framework change is introduced.

## Risks

- Filtering before day completeness is known can hide actual content. Filtering
  only the currently retained rows can misclassify a day after virtualization.
- A single empty-title parent may contain meaningful descendants or carry a task
  status. Ignoring either would hide a day that the confirmed rule retains.
- Hidden sections must retain enough day identity for later content updates to
  restore them, while existing retained-window memory limits still apply.
- App-bar title scaling differs from list text scaling; reusing numeric tokens
  alone does not guarantee equal rendered sizes at enlarged system text settings.
- Matching the timeline intentionally removes the stronger visual emphasis of
  the current date established by the previous typography decision.

## Consequences

Empty journals remain in the graph and in bounded presentation metadata while
retained, but contribute no list slots or geometry. Reconciliation can restore
qualifying content without a full graph reload. A completely evicted day is
reconstructed through the normal feed/page refresh lifecycle. The top date and
Capture remain available when all loaded sections are hidden.

Dates now share a single style and size policy across the app bar and timeline.
The fixed width reservation keeps their size stable when the error action appears.
Body text keeps its existing scaling and layout behavior.

## Questions

None outstanding. The user resolved both questions on 2026-09-08:

- **Q1 — Empty title:** Whitespace-only titles count as empty.
- **Q2 — Content beneath an empty title:** Keep the date visible when the single
  empty-title block has children or a task status.
