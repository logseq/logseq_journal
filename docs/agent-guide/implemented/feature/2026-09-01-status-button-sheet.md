# Status Button Sheet

## Problem

Rows need an exact status selector without losing the ten-value model or authoritative mutation guarantees.

## Proposal

Open the status sheet from the block's long-press Change status context-menu action. Keep existing current states readable until the user selects an explicit replacement.

### Status bottom sheet

Present a declarative Material modal bottom-sheet route using the pinned
`Ui.Navigation.Modal_bottom_sheet` API. Use detented sizing with `Medium` as
the only detent and the initial detent, enable drag dismissal, and provide the
required accessible drag-handle semantics. Also use bottom safe-area
accommodation, route focus, a dismissible barrier, and the application's
reduced-motion transition duration. Barrier tap, system Back, or downward
dismissal closes the sheet without changing status.

The sheet has a concise `Set status` heading and exactly seven selectable rows
in this order; `Now`, `Waiting`, and `Later` are not picker options:

1. `Backlog`
2. `Todo`
3. `Doing`
4. `In review`
5. `Done`
6. `Canceled`
7. `Clear`

Each row has a status icon, visible label, full-width minimum-size tap target,
and button semantics. Rows retain the sheet's neutral background and labels
retain the default text color. Only the icon uses the matching shared status
category color; `Clear` uses the neutral `No status` icon color. Color
supplements the literal label, icon, selected state, and semantics rather than
becoming the sole cue.
The option matching the current exact status is selected and cannot emit a
no-op request. `Clear` is selected only when the exact status is `No_status`.
If the current exact state is `Now`, `Waiting`, or `Later`, no sheet option is
selected. At the standard portrait viewport and `1.0` text scale, the `Medium`
detent shows the heading and all seven options at once. When viewport height or
text scaling makes that physically impossible, one primary vertical scroll
area keeps every option reachable without clipping or reducing the minimum
tap-target size.

Selecting an enabled option closes the sheet immediately and emits exactly one
existing `Journal_graph_request.Set_task_state` request. `Clear` maps directly
to `No_status`; every other option maps to the same-named exact task state. The
request uses the source block ID, latest authoritative revision, and a stable
mutation identity. It does not update the row optimistically.

If the source block disappears while the sheet is open, dismiss the sheet
without issuing a request. If authoritative status changes while it is open,
the sheet refreshes its selected option before a choice is admitted. Once a
selection is admitted, status and Delete actions remain gated until the
mutation becomes terminal. Success reconciles through the authoritative graph
projection. Failure or revision conflict leaves the authoritative status
unchanged and reports the existing accessible snackbar error after the sheet
has closed; reopening the sheet is the retry path.

## Decision

Use the existing status picker and authoritative Set_task_state path. Keep neutral row backgrounds, category-colored icons, literal labels and selection semantics.

## Alternatives considered

### Cycle statuses

Rejected because cycling cannot express the intended exact state reliably.

## Acceptance criteria

- The picker exposes Backlog, Todo, Doing, In review, Done, Canceled and Clear in that order.
- Clear maps to No_status. Existing Now, Waiting and Later values remain unchanged until explicit selection.
- Same-status choices admit no mutation; pending mutations and removed blocks remain fenced.
- Failure uses existing accessible feedback; success follows the authoritative projection.

## Consequences

Exact status selection and authoritative mutation behavior remain available from the long-press context menu. Block swipe entrypoints no longer exist.

## Risks

- Small viewports or large text require native scrolling to keep every option reachable.

## Questions

None. The existing status-selection contract remains in force.
