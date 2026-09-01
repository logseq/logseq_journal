# Sync Activity Progress Bar

## Problem

The timeline gives no persistent visual feedback while managed sync is connecting. This
operation can take long enough that the interface appears idle even though synchronization
is making progress. The requested location is the bottom edge of the pinned Today header,
immediately above its existing divider.

## Decision

Derive a binary connection-activity presentation state from the existing managed-sync
snapshot. Treat exactly `Connecting` as visible. Treat `Offline`, `Pulling`, `Submitting`,
`Current`, `Paused`, `Failed`, and an absent snapshot as hidden.

Pass that presentation state through the timeline page into `Journal_header.sliver`. When
active, render a two-logical-pixel-tall Material indeterminate linear progress indicator
across the header's bottom edge, immediately above the existing physical-pixel divider.
When inactive, omit the indicator entirely so the header retains its current geometry.
Keep the progress bar visible when the app bar collapses because sync activity is
independent of scroll position.

Expose a stable test identifier on the progress indicator. Cover the complete phase
partition with OCaml view tests, including the absent-snapshot case, so future sync-phase
changes cannot accidentally make idle states look active.

This decision changes only application presentation. It does not change the sync reducer,
the public interfaces under `spec/`, any Dune configuration, or sync transport behavior.

## Alternatives considered

### Determinate progress

Rejected because websocket connection does not expose a meaningful completion fraction.
Fabricating percentages would communicate false precision. The existing Material
indeterminate indicator truthfully communicates ongoing work.

### A textual sync-status label

Rejected because it would compete with the Today title and date, change header geometry,
and require more attention than a transient activity cue.

### A progress bar in timeline content

Rejected because it would scroll away and shift the feed. The pinned header provides
stable visibility without changing timeline layout.

## Acceptance criteria

- The pinned timeline header displays an indeterminate linear progress bar while the sync
  phase is `Connecting`.
- The progress bar is absent for `Offline`, `Pulling`, `Submitting`, `Current`, `Paused`,
  `Failed`, and before a sync snapshot is available.
- The indicator occupies the header's bottom edge above the existing divider, remains
  exactly two logical pixels tall, remains visible in expanded and collapsed header
  states, and does not add or move timeline content.
- Existing header layout, accessibility, theme, and timeline tests continue to pass.
- No files under `spec/`, no Dune files, and no files in the `bonsai_flutter` repository
  are modified.

## Consequences

- Rapid phase transitions can make the indeterminate indicator brief, but adding a minimum
  display duration would make the UI report activity after sync has completed.
- The indicator reports connection activity, not completion percentage; this is
  intentional because websocket connection exposes no meaningful progress total.
- The indicator is layered above the header's existing divider rather than replacing it,
  preserving the physical-pixel boundary in inactive states and the divider-count
  constraint.
- The complete OCaml test suite and Flutter host test suite verify the phase partition,
  indeterminate presentation, header-edge placement, and unchanged application behavior.
