# Capture Floating Action Button Slot

## Problem

The Journal route currently places
`Ui.Native_widget.Expandable_message_composer` in
`Material.scaffold ~bottom_navigation_bar`. The application also wraps the
component in horizontal padding before assigning that slot. This matched the
previous bonsai_flutter implementation, whose collapsed root manufactured a
72-point bottom-navigation region containing an end-aligned extended FAB.

bonsai_flutter has changed that contract. Framework commit
`270e553f19cd9934a63538468b045777b09af854` removes the composer's bottom safe
area padding, fixed height, inner padding, and alignment. The component is now
an extended FAB intended exclusively for
`Material.scaffold ~floating_action_button`; Scaffold owns its placement,
safe-area avoidance, directionality, and relationship to any real bottom bar.
The published iOS SDK repository containing the change is commit
`5f8f540e4ccfd1e1807294aec8ac5f229161e2da` (`dev.20`).

The application manifests still pin
`d182690aeaa82ad0a972756205c62e3b598e3c24`, and the synchronized Flutter host
still contains the old fixed-height component. The active OPAM switch already
uses `5f8f540e4ccfd1e1807294aec8ac5f229161e2da`, so the OCaml interface describes
the new FAB-slot contract while the checked-in generated host implements the
old bottom-navigation contract. This mixed state can hide an invalid placement
until the host is synchronized.

Leaving Capture in `bottom_navigation_bar` after synchronizing the update
would continue to make Scaffold reserve a persistent bottom region for a
control that is supposed to float. Depending on the constraints supplied to
that slot, the new FAB root may also receive bottom-bar geometry instead of its
intrinsic bounds. The result conflicts with the requested presentation: the
resting Capture control should be only a floating button, with no blank or
interactive band obstructing the bottom of the app.

Moving the component to the FAB slot intentionally changes only collapsed
placement. The current direct-capture behavior is already correct: one tap
opens the same framework-owned modal composer, Save admits the same mutation,
pending state prevents duplicate submission, success dismisses and resets the
draft, and failure preserves and restores the draft. Those behaviors must not
be redesigned as part of this placement update.

A real floating action button overlays the Scaffold body rather than reserving
layout height. Removing the bottom bar therefore lets the timeline reach the
bottom edge, but the final journal row may finish underneath the FAB when
scrolled fully to the end. The user confirmed that the timeline must include
scroll-content end clearance so the final row can move above the FAB without
restoring a persistent Scaffold bottom bar.

### Prior proposal

Update the application to the published bonsai_flutter revision
`5f8f540e4ccfd1e1807294aec8ac5f229161e2da`, synchronize the generated Flutter
host through `bonsai-flutter sync-host`, and consume the new
`Expandable_message_composer` contract without an application compatibility
path.

In the Journal Scaffold:

- pass the existing `capture` widget as `~floating_action_button:capture`;
- use `~floating_action_button_location:Ui.Material.End_float` explicitly so
  the resting placement remains end-aligned in both LTR and RTL layouts;
- remove `bottom_navigation_bar` entirely rather than leaving an empty or
  transparent placeholder;
- retain no `bottom_sheet` child, because the native component continues to
  own its modal route; and
- remove the application-owned horizontal padding around the collapsed
  component, because standard Scaffold FAB margins and safe-area placement now
  own that geometry.

The Scaffold must contain exactly one floating action button. Capture remains
mounted while disabled and retains its existing key, labels, icon, animation
intent, editor policy, Save action, and native event handler. Do not introduce
a separate application FAB, Stack overlay, bottom bar, or fallback composer.

Keep all behavior after activation unchanged:

- the FAB opens the framework-owned Material modal bottom sheet;
- focus, keyboard inset following, Safe Area, scrim, drag, Escape, and draft
  ownership remain in bonsai_flutter;
- whitespace-only text remains inadmissible;
- Save continues to emit the exact source and admit at most one
  `Journal_graph_request.Capture` while pending;
- Saving remains disabled and accessible;
- success inserts the returned block, advances the native key, clears the
  draft, dismisses the sheet, and restores the FAB; and
- failure keeps the exact draft and retry identity while restoring the editable
  composer and existing Save action.

Add end clearance inside the timeline's scrollable content, not as Scaffold
chrome. The clearance must be large enough for the standard extended FAB,
Scaffold's bottom margin, and the device bottom safe area, so the last real row
can scroll completely above the button. It must scroll away with content and
must not create a permanently reserved bottom band when the timeline has more
content. Use the framework's sliver or viewport padding contract where
possible; do not revive the obsolete route-level `bottom_navigation_bar`
placement or a compatibility-only `Bottom_clearance` model slot.

Update application tests to assert slot ownership rather than the old
bottom-navigation workaround. The logical Scaffold frame should report one
floating-action-button child at `End_float`, no bottom-navigation child, and no
bottom-sheet child. Existing direct-save tests should continue to exercise the
same native kind, properties, events, mutation lifecycle, and stable-key reset.

After host synchronization, add runtime layout coverage that distinguishes a
real overlay FAB from a reserved bottom band. The body must reach the
Scaffold's available bottom edge, the collapsed composer bounds must equal the
visible extended FAB bounds, and the device bottom safe area must be owned by
standard Scaffold placement. Runtime coverage must also prove that the final
journal row can be scrolled clear of the FAB on an iOS-sized viewport without
a stationary bottom band.

Update affected reference goldens only after the geometry assertions pass.
The resulting screen continues to use no more than three dividers. Do not edit
Dune files, `spec/` OCaml files, generated host source by hand, or OCaml files
in the bonsai_flutter repository.

## Decision

Adopt bonsai_flutter revision
`5f8f540e4ccfd1e1807294aec8ac5f229161e2da` and mount the existing
`Expandable_message_composer` as the Journal Scaffold's exclusive
`floating_action_button` at `End_float`. Remove the obsolete
`bottom_navigation_bar` placement and every application-owned collapsed FAB
wrapper. Preserve the existing modal composer and direct-capture lifecycle.

Add timeline scroll-content end clearance of 64 points plus the device bottom
safe-area inset. The 64-point base covers the standard 48-point extended FAB
and Scaffold's 16-point floating margin. The clearance scrolls with the
timeline so the last real row can move completely above Capture; it is not a
fixed Scaffold bar, synthetic timeline record, or compatibility path.

## Alternatives considered

### Keep Capture in `bottom_navigation_bar`

This preserves the current application call shape, but the synchronized
component no longer owns bottom-navigation geometry. Scaffold would still
reserve a bottom region for a floating control, so the app would retain the
obstruction the update is intended to remove.

### Wrap the new component to recreate the old 72-point band

Application padding, alignment, and a fixed-height wrapper could imitate the
old implementation. That would deliberately restore obsolete framework
behavior, duplicate Scaffold's safe-area and directionality logic, and create
a compatibility layer forbidden by the project rules.

### Position Capture in the body overlay

The existing body overlay could place the component with `Stack.positioned`.
That would make the application reproduce FAB margins, Safe Area behavior,
RTL placement, bottom-bar coexistence, semantics, and hit testing. The
dedicated Scaffold slot already owns these concerns and is now the component's
documented parent.

### Keep the old pinned framework revision

This avoids immediate application work but retains the framework bug: the
collapsed component is a FAB rendered inside a permanently reserved navigation
band. It also leaves the repository inconsistent with the user's requested
bonsai_flutter update and the active development switch.

### Reserve Scaffold bottom space to protect the final row

A real or transparent bottom-navigation child would prevent overlap, but it
would recreate a stationary bottom obstruction across empty, short, and long
timelines. If the final row needs protection, scroll-content end clearance is
more precise because it affects only the list's scroll range.

### Allow the FAB to overlay the final row with no scroll clearance

This is the smallest placement-only change and matches standard Scaffold body
geometry. It removes the bottom band, but a short or fully scrolled timeline
can leave content behind the button. This alternative remains available if
"no obstruction" refers only to removal of the persistent bottom region and
not to final-row readability.

## Acceptance criteria

- Application and worker manifests pin bonsai_flutter revision
  `5f8f540e4ccfd1e1807294aec8ac5f229161e2da`, and synchronized host artifacts
  come from that published revision.
- The Journal Scaffold owns exactly one `floating_action_button`, uses
  `End_float`, and owns no `bottom_navigation_bar` or `bottom_sheet`.
- The collapsed component is exactly one end-aligned Material extended FAB;
  its bounds do not fill the app width or reserve a fixed-height bottom region.
- The Scaffold body reaches its available bottom edge, and no blank,
  transparent, semantic, or hit-testable Capture band obstructs that edge.
- Scaffold owns FAB margins, Safe Area, and RTL placement. The application adds
  no collapsed-component padding or positional wrapper.
- Enabled and disabled Capture retain the same standard FAB geometry. Disabled
  Capture has disabled semantics and cannot open the composer.
- Activating the FAB opens exactly one modal composer with the same animation,
  first-frame focus, keyboard-inset following, Safe Area, scrim, drag, Escape,
  and draft-restoration behavior as before the placement change.
- The expanded composer still exposes exactly one trailing Save action. Empty
  text does not save, exact Unicode source is preserved, repeated pending taps
  cannot duplicate a capture, and keyboard Done does not become Save.
- Success and failure retain the existing direct-capture lifecycle, including
  key advancement only after success and mutation-identity reuse for an
  unchanged retry.
- Runtime tests prove that a collapsed Capture does not reduce Scaffold body
  height on an iOS-sized viewport and that the last real row can scroll fully
  above the FAB.
- Light, dark, high-contrast, text-scale 3.2, RTL, Reduced Motion, macOS, and
  iOS verification cover the updated collapsed placement and unchanged modal
  behavior.
- The implementation adds no divider and remains within the project maximum of
  three dividers.
- No obsolete bottom-navigation placement, generated-host hand edit, fallback
  composer, compatibility mode, Dune edit, `spec/` OCaml edit, or
  bonsai_flutter repository OCaml edit remains.

## Consequences

The resting Journal no longer allocates a bottom-navigation region for Capture.
Its Scaffold body reaches the available bottom edge while standard Scaffold
geometry positions one end-aligned extended FAB above the device safe area.

Long timelines gain enough trailing scroll range for their final real row to
move above the FAB. That range is presentation-only and scrolls away; timeline
record counts, pagination, sparse extents, visible-range identity, and empty
state semantics continue to describe real journal content only.

Opening Capture, editing, saving, duplicate-submission prevention, success,
failure, retry identity, keyboard synchronization, dismissal, and draft reset
retain their existing behavior. The implementation changes framework pinning,
host synchronization, Scaffold slot ownership, scroll presentation, layout
tests, and affected goldens without adding another Capture path.

## Risks

- A Scaffold exposes one FAB slot. Capture becomes its exclusive owner; adding
  another simultaneous primary FAB would require a separate product decision.
- Standard Scaffold placement changes exact margins from the old application
  padding. Coordinate-based goldens must be updated from observed standard FAB
  geometry rather than preserving old values.
- Scroll-content end clearance must not become a stationary blank region or
  move short empty-state content away from its intended alignment.
- Sparse-sliver counts and visible-range calculations must
  remain about real timeline records. Encoding clearance as a synthetic model
  slot would reintroduce obsolete state and can affect pagination.
- Synchronizing the host changes generated framework files in a worktree that
  already contains unrelated application work. Implementation must preserve
  those user changes and review generated diffs separately.
- A mismatched OPAM pin, manifest pin, iOS SDK package, or synchronized host can
  make OCaml tests pass against one component contract while runtime tests use
  another. Verification must establish one published revision across layers.

## Questions

None. The user confirmed scroll-content end clearance that lets the final real
row move completely above Capture without restoring a fixed bottom bar.
