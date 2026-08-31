# Capture Task and Swipe Status Actions

## Problem

Direct Capture currently creates only plain top-level blocks. The compact
`Expandable_message_composer` exposes one trailing Save action, while
`Journal_capture.task_state` always returns `No_status` and every admitted
capture serializes `No_status`. A user who intended to capture a task must save
the block, open Detail, and then use the Detail task action. That interrupts the
fast-capture flow and makes task intent unavailable when the block is created.

The timeline has the inverse problem. A top-level row presents task status as a
noninteractive four-category color rail, and its only swipe action is Delete in
the logical-end pane. In LTR, a leftward swipe reveals Delete. There is no
logical-start pane, so a rightward swipe cannot set a block to `No_status`,
`Todo`, `Doing`, or `Done` without opening Detail.

The two interactions have different intended breadth. Capture needs one
optional task flag: a plain capture uses `No_status`, and a task capture uses
`Todo`. The timeline needs four explicit target statuses rather than Detail's
lossy toggle. The exact model still preserves `In_review`, `Now`, `Canceled`,
`Backlog`, `Waiting`, and `Later`; the new row pane does not remove those values
or coerce them until the user explicitly selects one of its four targets.

The framework and mutation lifecycles must remain explicit. Capture must use the
composer's theme-owned Material IconButton with distinct unchecked and checked
task icons plus state-aware accessibility text. Row status changes must use the
displayed block's exact revision, prevent duplicate or concurrent mutation,
handle conflicts and failures, and reconcile through the authoritative graph
projection. Neither interaction may update only local presentation state.

## Decision

Add a binary Material task selector to Direct Capture and a four-action
logical-start status pane to mutation-enabled top-level timeline rows. Keep
Capture limited to `No_status` and `Todo`; keep exact status selection in the
row pane limited to `No_status`, `Todo`, `Doing`, and `Done`.

### Capture task IconButton

Render a Material task IconButton in the expanded Capture composer's bottom
action row at the logical leading edge. Save remains at the logical trailing
edge. The task action is visible even when the draft is empty so task intent can
be selected before typing.

The IconButton has exactly two states:

```text
Unchecked task icon -> No_status
Checked task icon   -> Todo
```

The icon, selected presentation, tooltip, and accessibility label must make the
intended capture type understandable without relying on color. The unchecked
state uses the composer's plain IconButton style and an unchecked task icon. The
checked state uses its filled IconButton style and a checked task icon. Their
state-aware tooltips announce `Capture as task, off` and `Capture as task, on`.
Do not imitate the action with generic decoration or create a second nested
interactive control.

This feature uses the published, pinned `bonsai_flutter`
`Expandable_message_composer.button` API. The application does not modify
generated Flutter host files, create a second application-owned composer, or
modify any OCaml file in the `bonsai_flutter` repository from this worktree.
Before application changes, the installed switch and generated host must be
synchronized to the repository's selected framework revision.

`Journal_capture` owns the selected task intent. Pressing the task IconButton
must preserve the exact draft, selection, composing range, focus, active modal
route, and FAB presentation. `admit_save` snapshots the exact untrimmed source
and current task intent into the same `Journal_graph_projection.capture`
command. It must no longer hard-code `No_status` or expose a `task_state`
accessor that ignores its state.

During a pending save, the editor, task IconButton, and Save action are disabled.
Success dismisses the composer and resets both the draft and task IconButton for
the next capture. Failure keeps the exact draft, selected task intent, and
admitted request. Re-saving an unchanged failed capture reuses its mutation
identity. Changing either text or task intent after a terminal failure ends the
failed attempt under the same direct-capture replacement rules; it must not
silently turn an unknown commit outcome into a new mutation.

Deliberately dismissing the composer without saving preserves the exact draft
and selected task intent. Reopening the composer restores both values; only a
successful persistence resets them for the next capture.

### Four explicit row status actions

Add a logical-start `Slidable` action pane to every mutation-enabled top-level
block row. With `use_text_direction:true`, a rightward swipe reveals the pane in
LTR and a leftward swipe reveals it in RTL. The existing logical-end Delete pane
retains its direction and behavior. Direct-child preview rows remain
noninteractive and receive no Slidable panes.

Dragging only reveals the bounded pane. It never changes status, including
after a full-width drag. A user must press one of four visible actions:

```text
No status | Todo | Doing | Done
```

Each action maps directly to its exact `Journal_model.task_state` value and a
distinct stable positive action ID. The IDs must remain distinct from the
existing Delete action ID. The action matching the block's current exact status
is visibly selected or disabled and cannot admit a no-op mutation. When the
current status is `In_review`, `Now`, `Canceled`, `Backlog`, `Waiting`, or
`Later`, none of the four actions is selected; pressing any action explicitly
replaces that exact status with the chosen target.

The pane uses stationary `Behind` motion, `drag_dismissible:false`, no
dismissible pane, and a bounded extent large enough for four minimum-size
targets at the narrowest supported viewport. Each target uses a concise visible
label plus the existing task/status icon vocabulary. The pane uses
non-destructive, theme-owned Material container and foreground roles and remains
visually distinct from the error-colored Delete pane. Its layout must remain
usable at large text scale without changing the row's known vertical extent or
adding a divider.

Both panes remain in the shared `journal-timeline` auto-close group. Opening
either side of a row closes every other open row. Scrolling or tapping away
retains the existing close behavior.

### Row mutation ownership and failure

Timeline state owns at most one pending row status mutation containing the
target block ID, expected revision, requested exact status, and stable mutation
ID. Pressing an enabled status action emits exactly one
`Journal_graph_request.Set_task_state`. While it is pending, all row mutation
actions are gated so a second status selection or Delete cannot race against
the same revision. Virtualization must never retarget a stale action event to a
different block.

Success reconciles through the authoritative projection, updates the exact
status, rail category, row semantics, and selected status action, then closes
the pane. Failure or revision conflict also closes the pane, restores the row to
an actionable state, and shows an accessible error through the application's
standard error/snackbar presentation. There is no retry action inside the
pane. A user retries explicitly by reopening the pane and selecting a status
again; the new attempt uses the latest authoritative revision and a fresh
mutation identity only after the previous outcome is known to be terminal.

This proposal does not change Detail status editing, the ten-value task-state
model, status-rail categories, Capture child creation, timeline extent
calculation, direct-child behavior, or the maximum of three dividers. No file
under `spec/`, no Dune file, and no OCaml file in the `bonsai_flutter`
repository is in application implementation scope.

## Alternatives considered

### Use a FilterChip

A labeled FilterChip can communicate optional task intent more explicitly, but
the existing composer protocol owns Material IconButton actions. Embedding a
FilterChip as an IconButton child would create nested interactive semantics, and
adding another composer control protocol is unnecessary for this binary action.
Rejected because the user selected the existing composer IconButton.

### Use a Checkbox or Switch in Capture

A Checkbox suggests a labeled form row, while a Switch usually represents an
immediately applied or persistent setting. The value belongs only to the block
being drafted, and either control would require a composer layout distinct from
the existing compact action row.

### Support more than Todo in Capture

A SegmentedButton or picker could expose additional states, but Capture is
deliberately limited to plain-block or task intent. Exact status refinement can
happen from the row pane or Detail after creation.

### Reuse Detail's task toggle in the row

Detail maps every active status to `Done` and maps `Done` or `Canceled` to
`Todo`. Rejected because the row must expose four explicit targets rather than
perform a lossy implicit cycle.

### Put every exact status in the swipe pane

Nine nonempty statuses plus `No status` exceed the capacity of a row action
pane. The selected four targets cover the requested quick actions without
changing the model's ability to preserve the remaining exact statuses.

### Change status as soon as the row is swiped

Gesture-only activation makes horizontal intent mutate data and offers no
equivalent explicit tap target. Rejected. Swiping reveals actions; pressing an
action performs the mutation.

### Make direct-child previews actionable

Direct-child previews are bounded context inside a parent row, are not currently
independent Slidable items, and cannot be deleted independently. Rejected to
keep the new status actions aligned with existing top-level row ownership.

### Keep the pane open after failure

An in-pane retry would add a second failure lifecycle inside virtualized row
state and could reuse a stale revision. Rejected. Failure closes the pane and
uses the standard error presentation; a later explicit selection starts from
authoritative state.

## Consequences

Direct Capture now retains draft text and binary task intent together until an
authoritative save succeeds. Deliberate composer dismissal therefore behaves as
a reversible presentation change rather than cancellation; users must save
successfully to reset the next capture to an empty plain block.

Top-level timeline rows now expose four explicit status mutations without a
Detail round trip. The wider logical-start pane increases horizontal gesture
density, but each mutation remains an explicit button press and shares one gate
with Delete. Conflicts require an authoritative refresh and a later explicit
retry, which avoids optimistic status drift at the cost of one additional user
action after concurrent edits.

The compact horizontal icon-and-label layout keeps all four targets within the
known row extent at large text scale. Full status names remain available through
button semantics when a narrow action visually ellipsizes its label.

The implemented behavior has the following verified properties:

- Direct Capture renders a composer-owned Material task IconButton at the
  logical leading edge of the expanded composer action row, with Save at the
  logical trailing edge.
- The unchecked IconButton persists `No_status`; the checked IconButton persists
  `Todo`. Capture exposes no other task states.
- Capture persists the selected task state and exact untrimmed source in one
  request. It never saves a visible checked action as `No_status` or a visible
  unchecked action as `Todo`.
- IconButton selection survives text edits, IME composition, keyboard
  appearance, modal configuration updates, a failed save, and an unchanged
  retry. Deliberate composer dismissal preserves the exact draft and selected
  task intent for reopening. Only successful persistence resets them.
- While saving, the editor, task IconButton, and Save action cannot admit a
  second or contradictory request.
- The application uses the published, pinned `bonsai_flutter` composer button
  API without a hand-drawn control, nested interactive control, generated-host
  patch, or application-owned replacement composer.
- Every mutation-enabled top-level block row has a logical-start status pane
  with exactly four visible actions ordered `No status`, `Todo`, `Doing`, and
  `Done`, and retains its logical-end Delete pane.
- Direct-child previews have no status or Delete pane.
- In LTR, a rightward swipe reveals the status pane and a leftward swipe reveals
  Delete. RTL mirrors physical directions while preserving logical-start status
  and logical-end Delete meanings.
- Partial and full-width drags only reveal or close the pane. No drag emits a
  `Set_task_state` request.
- Pressing an enabled status action emits exactly one `Set_task_state` request
  with the displayed block ID, exact projected revision, selected target status,
  and a stable mutation identity.
- The action matching the current status cannot emit a no-op mutation. Blocks
  in any other exact status remain unchanged until one of the four actions is
  pressed.
- A pending row status mutation prevents another status mutation and Delete
  from racing against the same block revision. Stale native events cannot target
  a virtualized replacement row.
- Success updates the row only through authoritative projection and refreshes
  its exact status, rail category, semantics, and selected action.
- Failure or revision conflict closes the pane, restores an actionable row, and
  displays an accessible error. No retry control remains in the pane.
- Opening either pane auto-closes every other row. Scrolling and tapping away
  retain existing close behavior.
- All four status targets meet minimum touch size and remain readable at the
  narrowest supported viewport, RTL, large text scale, light presentation, and
  high contrast without changing row extent or introducing a fourth divider.
- OCaml tests inspect typed composer button and `Slidable.For_testing` props,
  exact action IDs, checked/disabled state, and event routing. Flutter runtime
  tests cover Capture selection, save/failure/retry, four row actions,
  current-status no-op prevention, right and left swipes, full-width drags
  without mutation, sibling auto-close, error closure, RTL, large text, reduced
  motion, and accessibility semantics.
- `dune runtest`, `dune build @fmt`, `spec-dev-tool check --all`, and the
  framework-aware Flutter analyze/test commands complete successfully.

## Remaining tradeoffs

- An icon-only task selector could be ambiguous if the two glyphs or tooltip
  states are too similar. The checked and unchecked icons plus state-aware
  accessibility text must communicate the current intent without color.
- Four labeled actions require a wider start pane than the existing one-action
  Delete pane. Poor extent or label choices could overflow narrow viewports or
  compete with vertical scrolling.
- Two horizontal panes increase gesture competition with platform back gestures
  and timeline scrolling. Threshold and edge behavior need real iOS and Android
  runtime coverage.
- Status and Delete target the same block revision. Independent pending paths
  could race unless they share one mutation gate.
- Blocks with `In_review`, `Now`, `Canceled`, `Backlog`, `Waiting`, or `Later`
  have no selected action in the four-target pane. Accessibility semantics must
  still announce the exact current status before presenting the available
  replacements.
- Capture state receives native text snapshots and composer button events
  separately. The application keeps visible selection and admitted request
  state synchronized across delayed OCaml frames, but this remains a protocol
  boundary that needs regression coverage.
