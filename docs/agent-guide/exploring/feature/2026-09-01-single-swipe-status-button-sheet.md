# Single Swipe Status Button Sheet

## Problem

The logical-start timeline swipe pane currently exposes four full-bleed actions:
`No status`, `Todo`, `Doing`, and `Done`. This makes common transitions direct,
but it consumes 80% of the row width, presents four competing color blocks, and
still cannot set several exact task states that the journal model preserves.
In particular, `Backlog`, `In review`, and `Canceled` require a Detail round
trip even though they are ordinary task-status choices.

The requested interaction replaces that dense quick-action pane with one
button. The button represents the row's current exact status and opens a modal
bottom sheet for status selection. The sheet must expose exactly these targets:

```text
Backlog | Todo | Doing | In review | Done | Canceled | Clear
```

`Clear` means `Journal_model.No_status`; it does not create another model
status. The exact model also contains `Now`, `Waiting`, and `Later`. Existing
blocks with those values must remain readable and unchanged until the user
selects one of the seven sheet choices. The interaction therefore needs a
defined presentation for every existing exact status even though the picker is
intentionally narrower than the model.

The replacement must retain the existing mutation guarantees. A swipe gesture
must never mutate status by itself, selection must use the displayed block's
authoritative identity and revision, concurrent row mutations must remain
gated, and failures must use the application's standard accessible feedback.
The existing logical-end Delete action and direct-child noninteractivity are
outside this change.

## Proposal

### Logical-start swipe action

Remove the obsolete four-action quick-status pane and its 80%-width layout.
Give every mutation-enabled top-level row exactly one logical-start status
action. In LTR a rightward swipe reveals it; RTL mirrors the physical direction
while keeping status at logical start. The logical-end Delete action remains
unchanged.

The action shows both the current exact status icon and a short visible status
label, rather than advertising a target transition or using an icon-only
control. For a block without a status, the action label is `No status`; `Clear`
is reserved for the command in the sheet. Its accessibility label follows the
form `Change status, current status <name>` so that color is never the only
status cue.

The button uses four status colors. Among the seven selectable values,
`Backlog` owns the fourth color by itself:

| Current exact status | Button color role |
| --- | --- |
| No status | No status color; use the surrounding surface rather than a status fill |
| Todo | Existing Todo color |
| Doing, In review, Now | Existing Doing color |
| Done, Canceled | Existing Done color |
| Backlog | Dedicated Backlog color, reusing the existing Later rail color |
| Waiting, Later | Backlog/Later category color when rendering an existing value |

`No status` deliberately has no status-colored background. Its icon, label,
foreground, focus, pressed, and disabled states must still be visible against
the surrounding surface. The four colored roles are Todo, Doing, Done, and
Backlog. Every role must have an explicitly paired foreground for Light and
Dark appearances and meet the existing contrast requirements. The Backlog role
reuses the existing Later rail background, which currently has no paired
foreground, so an explicit foreground pair is required before implementation.
High Contrast follows the project's current status-palette policy unless a
contrast check demonstrates that a dedicated pair is required.

The single action keeps stationary `Behind` motion, is not drag-dismissible,
and never changes status from a partial or full-width drag. Pressing it closes
the slidable pane and opens the status sheet. While another mutation is
pending, the Slidable and its status button remain disabled under the existing
row mutation gate.

### Status bottom sheet

Present a declarative Material modal bottom-sheet route using the pinned
`Ui.Navigation.Modal_bottom_sheet` API. Use content-bounded sizing, a drag
handle, bottom safe-area accommodation, route focus, a dismissible barrier,
and the application's reduced-motion transition duration. Barrier tap, system
Back, or downward dismissal closes the sheet without changing status.

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
and button semantics. Color may supplement the row but must not be its sole
cue. The option matching the current exact status is selected and cannot emit
a no-op request. `Clear` is selected only when the exact status is
`No_status`. If the current exact state is `Now`, `Waiting`, or `Later`, no
sheet option is selected.

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

### Scope boundaries

This exploration changes the top-level timeline status-selection UI only. It
does not change Direct Capture, Detail status behavior, the ten-value task
state model, status serialization, status-rail category mapping, Delete,
direct-child previews, row extent calculation, or the maximum of three
dividers. No compatibility layer or fallback four-action pane is retained.

Implementation must not modify any OCaml file under `spec/`, any Dune file, or
any OCaml file in the `bonsai_flutter` repository unless separately and
explicitly authorized.

## Alternatives considered

### Keep four quick actions and add a fifth picker action

This preserves one-tap access to the existing quick states, but makes the
already-wide pane denser and conflicts with the requirement that right swipe
show only one button.

### Make the swipe button cycle statuses

A cycle avoids a modal route, but hides the next transition, cannot efficiently
reach seven targets, and risks accidental mutation from an action whose target
is not visible. It also fails the requested bottom-sheet interaction.

### Show all ten model states

An exhaustive picker would preserve every possible exact target, but the
requested set deliberately excludes `Now`, `Waiting`, and `Later`. Existing
values can still be represented by the current-status button and preserved
until the user explicitly chooses an available replacement.

### Give every exact status a unique new color

Unique colors could distinguish all ten exact values, but would expand this UI
change into a new palette design and weaken the existing category relationship
between the row rail and status action. Reusing category colors keeps the
button consistent with the row's existing visual status cue.

### Limit the picker to three colors

Sharing one of Todo, Doing, or Done with Backlog would remove Backlog's distinct
planning category. Use four colors instead: Todo, Doing/In review,
Done/Canceled, and Backlog. `No status` remains unfilled and is not a fifth
color.

### Use an application-specific overlay instead of navigation

The pinned framework already exposes a declarative Material modal-bottom-sheet
presentation with barrier, focus, sizing, dismissal, restoration, and
transition ownership. A custom stack overlay would duplicate those mechanics
and accessibility responsibilities.

## Acceptance criteria

- Every mutation-enabled top-level timeline row has exactly one logical-start
  status button and exactly one logical-end Delete button.
- Direct-child preview rows remain noninteractive and have neither pane.
- The old `No status / Todo / Doing / Done` four-action pane, its action IDs,
  and its 80%-width geometry are removed rather than retained as a fallback.
- The status button contains both an icon and visible status text. Its label,
  icon, semantics, and category presentation reflect the block's exact current
  status, including `No status`, `In review`, `Now`, `Canceled`, `Backlog`,
  `Waiting`, and `Later`; `No status` has no status-colored fill.
- The selectable statuses use exactly four colors: Todo, Doing/In review,
  Done/Canceled, and a distinct Backlog color. `No status` is unfilled.
- Swiping only reveals the button. Pressing the button opens one Material modal
  bottom sheet and does not itself emit `Set_task_state`.
- The sheet presents exactly `Backlog`, `Todo`, `Doing`, `In review`, `Done`,
  `Canceled`, and `Clear`, in that order, with accessible full-width targets.
- The current option is selected and disabled. `Clear` is selected for
  `No_status`; none is selected for `Now`, `Waiting`, or `Later`.
- Choosing an enabled option dismisses the sheet immediately and emits exactly
  one authoritative `Set_task_state` request for the source block. `Clear`
  emits `No_status`; a later failure is reported by accessible snackbar.
- Barrier tap, system Back, drag dismissal, a missing source block, and tapping
  the already-current option emit no status request.
- Pending, success, conflict, failure, stale-event, virtualization, shared
  auto-close, scrolling, RTL, reduced-motion, Light, Dark, High Contrast, text
  scale, and restoration behavior have focused coverage.
- Every colored button role has a foreground pair that meets ordinary-text
  contrast, the unfilled `No status` button remains legible in every
  appearance, color is not the sole status cue, and the screen retains no more
  than three dividers.
- Focused OCaml tests, source-boundary checks, generated-host checks, Flutter
  tests, analysis, and updated real-runtime goldens pass.

## Risks

- Common transitions now require a swipe, button press, and sheet selection
  instead of a swipe and direct action press.
- The picker intentionally cannot create `Now`, `Waiting`, or `Later`; selecting
  another option from one of those states replaces the exact value.
- Category colors do not visually distinguish `Doing` from `In review` or
  `Done` from `Canceled`. Existing `Waiting` and `Later` values also reuse the
  Backlog/Later category color even though they are not picker choices. `No
  status` has no status color, so the label, icon, and semantics remain
  essential.
- The Backlog color reuses a rail color that needs a verified foreground role
  before it can safely fill a full button.
- A modal route outlives the transient slidable pane, so block removal,
  authoritative refresh, navigation changes, and restoration must not leave a
  stale picker capable of mutating a recycled row.
- Seven rows may exceed content-bounded height at large text scale or on a
  small landscape viewport; the sheet content must become scrollable without
  clipping targets or adding excess dividers.

## Questions

- None. The user confirmed four colors, with Backlog owning the fourth color,
  and an unfilled `No status` role.
