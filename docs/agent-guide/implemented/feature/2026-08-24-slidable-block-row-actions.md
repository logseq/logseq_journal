# Slidable Block Row Actions

## Problem

Top-level Journal block rows currently use the removed
`Ui.Native_widget.Swipe_action` API for logical-end swipe deletion. The updated
`bonsai_flutter` dependency replaces native-widget kind 2 with the version 3
`Ui.Native_widget.Slidable` API backed by `flutter_slidable`. The application
therefore still refers to an obsolete module and its byte-level tests describe
an obsolete protocol.

The old presentation also does not produce the intended Material 3 layering.
During a delete gesture, the destructive color can read as if the complete row
became red. The desired result is a stationary red delete action below an
opaque, theme-colored row that moves above it and has a rounded exposed edge.
The replacement must retain logical-direction behavior, variable row extents,
focus, accessibility, the single-mutation gate, staged delete with Undo, and
the current rule that direct-child previews cannot be deleted independently.

This is not only a renderer substitution. `Slidable` distinguishes action
activation from pane dismissal, can remain partially open, and can
automatically close sibling rows. The product decision is that swiping only
opens the action menu; it must never delete a block. Deletion requires an
explicit press on the visible action. These differences must be represented
deliberately so that the Journal timeline remains a known-extent varied sliver.

## Proposal

Replace every application use of `Ui.Native_widget.Swipe_action` with
`Ui.Native_widget.Slidable`. Remove the old payload assumptions and do not add
an adapter, fallback, or compatibility alias.

Each deletable top-level row should own one logical-end action pane. Keep
`use_text_direction:true` so the pane opens with a left swipe in LTR and a right
swipe in RTL. Use `Behind` motion because it keeps the destructive action
stationary while the row moves above it, matching the requested two-layer
presentation. Do not add a logical-start pane.

The end pane should contain one enabled custom `Slidable.action` with a stable
positive action ID. Its compact child must display both the Material delete
icon and the visible label `Delete` without overflowing the shortest supported
44 logical-pixel row. Its background and foreground should retain the existing
Material error roles represented by
`Journal_visual_tokens.destructive_swipe_action`, and its semantics should
expose the complete accessibility label `Delete block and all descendants`.
Give the pane an explicit extent ratio near the old 96 logical-pixel action
width rather than accepting `Slidable.action_pane`'s 0.5 default; `0.25` is the
initial candidate for the supported 390 logical-pixel reference viewport.

Do not attach `Slidable.dismissible`, and set `drag_dismissible:false`
explicitly. Any swipe distance, including a full-width drag, may only open or
close the bounded action pane. It must not emit `Dismissed` and must not mutate
timeline state. Configure explicit open and close thresholds after runtime
gesture tuning so a deliberate left swipe opens reliably without making
vertical scrolling feel sticky.

Map only `Action_pressed delete_action_id` to the existing staged-delete
request. Ignore every other action ID and every `Dismissed` event defensively.
The mutation gate must still prevent a repeated press from enqueueing a second
mutation. Preserve the existing five-second Material snackbar, Undo behavior,
durable commit deadline, failure recovery, and focus restoration.

Place all Journal row slidables in one auto-close group and wrap the generated
application host once with `flutter_slidable`'s
`SlidableAutoCloseBehavior`. The typed OCaml viewport cannot be wrapped by an
ordinary child widget without discarding its vertical viewport evidence, so
the mechanical Flutter host is the nearest common ancestor that preserves the
typed varied sliver. Opening a row should close another open row, tapping
another row should close the open row, and scrolling should close open
actions. The group tag must be timeline-stable and must not be derived from an
individual block ID.

The moving foreground must paint an opaque Material surface. `Slidable` and
`BehindMotion` move the supplied child but do not create that surface, so each
deletable row uses a compact `Morphing_surface`. This preserves the active
Material theme's `colorScheme.surface` without turning rows into semantic
Cards or introducing fixed light/dark colors. The public OCaml API does not
expose Slidable drag progress or a theme-derived, one-edge rounded clip. The
opaque moving foreground therefore remains square. The destructive action is
square as well and paints one-physical-pixel Material dividers at its revealed
top and bottom row boundaries. This is an explicit limitation of the
no-`bonsai_flutter`-changes decision rather than a theme ownership workaround.

Expected application scope is `app/journal_timeline.ml` and, only if required
by the selected foreground-surface solution, `app/journal_row.ml` and
`app/journal_visual_tokens.{ml,mli}`. Test scope includes
`test/journal_semantics_test.ml`, `test/application_view_test.ml`,
`test/logseq_db_worker_application_integration_test.ml`,
`test/source_boundary_test.ml`, and
`flutter/test/journal_runtime_golden_test.dart` plus its swipe golden. No file
under `spec/`, no dune file, and no OCaml file in the `bonsai_flutter`
repository is in scope.

## Decision

Adopt `Ui.Native_widget.Slidable` with one logical-end `Behind` pane, a `0.25`
extent ratio, explicit `drag_dismissible:false`, and no dismissible pane. Use a
custom action ID `1` whose compact child renders a 16 logical-pixel Material
delete icon and visible `Delete` label. Only `Action_pressed 1` enters the
existing staged-delete path; all dismissal and unknown action events are
inert.

Use `Morphing_surface` in its compact state for the opaque theme-owned moving
row. Keep the destructive action square and mark its revealed row extent with
top and bottom one-physical-pixel Material dividers. Wrap the generated host in
`SlidableAutoCloseBehavior` so the shared
`journal-timeline` group auto-closes sibling rows while preserving the typed
OCaml vertical viewport. Do not change `bonsai_flutter` and do not introduce a
Card, fixed surface color, compatibility adapter, or full-swipe delete path.

The requested drag-progress-aware rounded edge on the moving foreground is not
representable by the installed public API. The delivered visual keeps the row
opaque above a stationary red pane. The action intentionally has no rounded
corners. A future exact foreground-edge treatment requires a separately
approved framework API.

## Alternatives considered

### Retain `Native_widget.Swipe_action`

Rejected. The updated framework removed the public module and reused native
widget kind 2 for the version 3 `Slidable` protocol. Keeping the old path would
require a compatibility layer expressly disallowed by repository policy and
would forfeit the maintained `flutter_slidable` behavior.

### Attach `DismissiblePane` for full-swipe deletion

Rejected. The product decision requires every swipe to stop at the action menu
without deleting. Only pressing the visible `Delete` action may stage a
deletion.

### Use `Drawer`, `Scroll`, or `Stretch` motion

Rejected for the current visual intent. These motions move or resize the
action content as the pane opens. `Behind` directly models a stationary red
background revealed by a moving foreground row.

### Wrap each row in `Ui.Material.card`

Rejected. A Card communicates an independent grouped-information surface and
the current OCaml API does not expose the color, shape, margin, or clipping
controls needed here. Its default margin and shape would also alter resting
timeline geometry. The foreground needs a Material surface implementation, not
Card semantics.

### Keep raw native payload assertions

Rejected. `Native_widget.Slidable.For_testing.decode_props_exn`,
`encode_action_pressed`, and `encode_dismissed` expose typed protocol tests.
Tests should assert the supported public contract instead of offsets from the
removed swipe-action version.

## Acceptance criteria

- Production code contains no reference to `Ui.Native_widget.Swipe_action`,
  and no test helper decodes or synthesizes the removed version 2 swipe
  payload. Boundary tests may retain the obsolete symbol only as a forbidden
  source pattern.
- Every delete-enabled top-level row has exactly one horizontal logical-end
  `Slidable` pane using `Behind` motion and one destructive delete action;
  direct-child previews and delete-disabled rows have no slidable wrapper.
- In LTR, dragging left reveals the delete action. In RTL, dragging right
  reveals the same logical-end action. Dragging in the opposite direction does
  not reveal an action.
- The revealed destructive action displays both the Material delete icon and
  the visible text `Delete`.
- The foreground row remains opaque in its original Material surface color and
  moves above the red pane. The destructive action is square and its revealed
  top and bottom boundaries each contain a one-physical-pixel Material divider.
  The resting row and its known extent gain no Card margin, elevation,
  permanent rounded gaps, or fixed light/dark surface color.
- Swiping any distance only opens or closes the action pane. No swipe emits a
  delete request, removes a row, or shows the Undo snackbar.
- Pressing the visible `Delete` action stages exactly one delete through the
  existing mutation gate and shows the same five-second Undo snackbar. Undo,
  deadline commit, failure recovery, and focus restoration remain unchanged.
- A canceled swipe does not delete. The app ignores any unexpected `Dismissed`
  event, and stale action events cannot delete a different block after
  virtualization reuses surrounding slots.
- Only one Journal row can remain open. Opening another row, tapping another
  row, or scrolling the timeline closes the previously open pane without
  deleting.
- The delete action has an accessible label describing subtree deletion, and
  action activation remains available without requiring a drag gesture.
- One- through four-line rows, expanded parents, status rails, timestamps,
  dividers, direct-child layout, RTL geometry, text scaling, high contrast, and
  the maximum of three dividers retain their existing contracts.
- OCaml view and integration tests inspect typed `Slidable.For_testing` props
  and action events. Flutter runtime coverage verifies partial reveal,
  full-width drag without deletion, exposed-edge shape and colors, cancel,
  visible action text, action tap, sibling auto-close, RTL, reduced motion, and
  the updated open-pane golden.
- The implementation changes no file in the `bonsai_flutter` repository and
  introduces no application fallback for either `Swipe_action` or an absent
  foreground-surface capability.
- `dune runtest`, `dune build @fmt`, `spec-dev-tool check --all`, and the
  framework-aware Flutter analyze/test commands complete successfully. No bare
  `flutter build` command is used.

## Risks

- `Slidable.action_pane` defaults to a 0.5 extent ratio. Accepting that default
  would materially enlarge the action menu compared with the old 96-pixel
  action area.
- A future configuration change could accidentally attach a dismissible pane.
  Tests must prove that full-width swipes cannot emit a delete request and that
  unexpected `Dismissed` events are inert.
- The new wrapper emits action IDs independently from the row's block ID.
  Incorrect event routing could permit a stale row action to target another
  block.
- `BehindMotion` does not make a transparent row opaque and does not animate a
  foreground shape. Treating Slidable adoption alone as the visual fix would
  leave the requested rounded surface incomplete.
- The installed public APIs may not expose a theme-derived, non-Card foreground
  surface with drag-progress-aware corner shaping. Because `bonsai_flutter`
  changes are forbidden, that limitation may block the exact visual treatment
  and must be reported rather than bypassed with fixed light/dark colors.
- `Slidable` owns its own animations. Reduced-motion parity with the old custom
  wrapper must be measured; the OCaml API does not expose every controller
  duration.
- Auto-close state adds another stateful layer inside a virtualized timeline.
  Keys and the common group tag must remain stable across frame updates.

## Consequences

Journal deletion now uses the maintained `Slidable` protocol and separates a
reveal gesture from destructive activation. Full-width drags clamp to the
bounded action pane, and delete/Undo behavior continues through the existing
mutation gate. Typed OCaml tests no longer construct version 2 byte payloads,
while the real runtime golden records the open pane with icon and text.

The foreground is now an opaque theme-owned Material surface, so revealing the
pane no longer makes the complete row appear red. The action is square and its
top and bottom dividers make the revealed row extent explicit. The moving row's
exposed edge remains square until the framework exposes a theme-owned,
drag-progress-aware shape capability. This limitation is retained in the
implemented record because changing `bonsai_flutter` was explicitly out of
scope.

## Questions

- None. The user decided that swiping only reveals the action menu, deletion
  requires pressing a visible `Delete` action, and no `bonsai_flutter` change
  is allowed.
