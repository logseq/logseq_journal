# Capture FAB Expanding Bottom Input

## Problem

The Journal route previously mounted `Native_widget.Message_composer` as a
persistent `Material.scaffold` bottom sheet. The text field occupied the
largest Capture presentation while the user was reading, forced the timeline
to retain a synthetic bottom-clearance slot, and exposed editing UI before the
user requested it.

The application needs progressive disclosure: one resting Capture affordance,
followed by an input surface only after activation. Capture availability,
full-editor routing, and persistence remain OCaml-owned, while transient text,
focus, keyboard, gesture, and modal animation state should remain in Flutter.

The published `bonsai_flutter` revision
`6f2562e09d74d347a50b90541abdb4900e1e23da` adds the purpose-built
`Ui.Native_widget.Expandable_message_composer` component and makes the old
application-composed Capture path obsolete.

Official references:

- [Flutter `FloatingActionButton`](https://api.flutter.dev/flutter/material/FloatingActionButton-class.html)
  defines the Material primary-action control used by the collapsed state.
- [Flutter `ModalBottomSheetRoute`](https://api.flutter.dev/flutter/material/ModalBottomSheetRoute-class.html)
  defines the modal route, barrier, drag, safe-area, and animation behavior
  used by the expanded state.
- [Flutter `Scaffold`](https://api.flutter.dev/flutter/material/Scaffold-class.html)
  defines the `bottomNavigationBar` layout role that reserves body space for
  the resting affordance.

## Proposal

Pin all application and worker manifests to bonsai_flutter revision
`6f2562e09d74d347a50b90541abdb4900e1e23da` and replace the old Capture
composition with `Expandable_message_composer.create_with_handler`.

Mount the component as the Journal Scaffold's only `bottom_navigation_bar`.
Do not also set `floating_action_button` or `bottom_sheet`. In its resting
state, the framework component renders one end-aligned Material extended FAB
labeled `Capture`, applies the device bottom safe-area inset, and reserves a
fixed 72-point navigation-bar region. Disabled Capture remains visible with
disabled Material and semantics behavior.

Activating the FAB pushes a framework-owned Material
`ModalBottomSheetRoute`. The route owns the scrim, drag handle, rounded
surface, maximum width, safe-area behavior, keyboard inset animation, and the
embedded `MessageComposer`. It is not an inline `AnimatedContainer` morph and
does not require the OCaml tree to represent collapsed, intermediate, or
expanded geometry.

The expanded composer has these properties:

- one-to-five-line text input with the hint `Capture a thought`;
- a leading action that opens an empty full Capture editor;
- a trailing filled action that appears for non-empty text and opens the full
  Capture editor with the source preserved byte-for-byte;
- whitespace-only submit rejection in the OCaml event handler;
- a Flutter-owned `TextEditingController` and `FocusNode` whose draft survives
  dismissal and re-expansion while the native widget key remains stable;
- downward drag, scrim tap, and Escape dismissal;
- no dismissal merely because editor focus is lost; and
- disabled-state dismissal without discarding the staged draft.

Use the application motion token's 180 ms sheet-route duration. The Material
route owns its standard transition curve; the component's explicit ease-out
curve controls its `AnimatedPadding` keyboard-inset transition. The framework
mounts the modal sheet before focus is requested, listens to the route animation
status, and requests editor focus only after the forward route animation
completes. Reduced-motion mode sends a zero duration; the sheet then reaches the
mounted and focused state in the next frame.

Opening the OCaml-owned full Capture editor is a two-phase handoff. The button
event first records the pending source and disables the expandable component,
causing its imperative modal route to dismiss. The application opens the full
editor only after the dismissal interval has elapsed. This prevents the modal
route from retaining renderer child nodes while a new OCaml navigation page is
being applied. The handoff delay is `(2 * route_transition_ms) + 32 ms`, which
also provides one frame boundary in reduced-motion mode.

Remove the old timeline `Bottom_clearance` slot and all `safe_bottom` and
composer-clearance extent calculations. Scaffold layout now keeps the final
real timeline row above the bottom-navigation region. The timeline cache,
logical count, visible range, and sparse extent geometry therefore describe
only real headings, rows, previews, loading indicators, and continuations.

Give the native component and its icon children stable application keys. A new
component key is allocated after a Capture session is handed to the full
editor, resetting local draft state for the next session.

Generated files under `.bonsai-flutter` are synchronized with
`bonsai-flutter sync-host` and are never edited directly. This repository does
not add a host-side Scaffold, compatibility path, or fallback composer. It does
not modify Dune files, `spec/` OCaml files, or OCaml files in the
`bonsai_flutter` repository.

This decision supersedes the earlier product choice to retain a persistent
composer. It does not change the existing full Capture editor, graph mutation,
task-state, child-entry, or application-theme decisions.

## Decision

Implement the proposal with the published framework component at revision
`6f2562e09d74d347a50b90541abdb4900e1e23da`. Use its extended FAB and Material
modal bottom sheet as the only compact Capture path, remove the application
`Message_composer` and timeline-clearance implementation, and use the
disabled-then-delayed handoff for actions that open the OCaml full editor.

## Alternatives considered

### Keep the persistent `Message_composer`

This retains the existing input and avoids a modal transition, but it keeps an
editing surface visible during reading and requires synthetic timeline
clearance. It does not provide progressive disclosure.

### Compose a FAB and inline composer in OCaml

The logical protocol can render a FAB and a composer separately, but the app
would own transient focus, gesture, draft, and animation coordination across
two native subtrees. That splits the state boundary and cannot preserve an
uncontrolled Flutter text controller reliably.

### Implement an application-host Flutter wrapper

A host wrapper could own a Scaffold and modal sheet, but it would duplicate
Scaffold ownership and move product state and event routing out of the OCaml
application. It also requires a side channel for the full Capture route.

### Preserve the proposed inline geometry morph

The earlier exploration proposed one stable `AnimatedContainer` interpolating
between FAB and input widths. The published framework component instead uses a
real extended FAB followed by a Material modal bottom-sheet route. The modal
route provides maintained barrier, drag, focus, keyboard, accessibility, and
safe-area behavior, so the unpublished inline morph is no longer the selected
contract.

### Edit generated Flutter packages

Local edits could alter the component, but `sync-host` replaces generated
packages and would make dependency updates silently lose behavior. Framework
changes belong in bonsai_flutter and are consumed here only through a pinned
revision.

## Acceptance criteria

- The resting Journal route contains exactly one enabled extended FAB labeled
  `Capture`, one Scaffold `bottomNavigationBar`, no `MessageComposer`, no
  Scaffold `bottomSheet`, and no Scaffold `floatingActionButton` slot.
- Disabled Capture remains mounted, exposes disabled semantics, and cannot
  open the modal composer.
- Activating the FAB mounts one Material `BottomSheet` and one
  `MessageComposer`; standard motion focuses only after its 180 ms route
  transition, while reduced motion uses zero duration.
- The expanded surface follows keyboard and safe-area insets, supports text
  scale 3.2, and remains within narrow mobile bounds.
- Downward drag dismisses the composer, restores the FAB, and preserves a
  Unicode draft byte-for-byte for re-expansion.
- Whitespace-only submit is a no-op. Non-empty submit disables and dismisses
  the native composer before opening the full editor with the exact source.
- The timeline contains no synthetic Capture clearance and its final real row
  is not obscured by the bottom-navigation affordance.
- Light, dark, high-contrast light, and high-contrast dark runtime tests pass;
  the two light reference goldens show the collapsed FAB and valid swipe
  threshold state.
- OCaml view, worker integration, timeline state, adaptive, semantics, source
  boundary, and full build tests pass.
- macOS Debug and no-codesign iOS arm64 builds pass with the controlled
  bonsai_flutter toolchains.
- The feature introduces no divider and rendered screens remain within the
  project limit of at most three dividers.
- No generated `.bonsai-flutter` source, Dune file, `spec/` OCaml file,
  bonsai_flutter OCaml file, compatibility layer, or fallback path is changed.

## Consequences

The resting Journal now reserves only the framework component's 72-point
bottom-navigation region and renders an extended `Capture` FAB. The expanded
input is an imperative Material modal route owned entirely by the native
component. Timeline logical counts and sparse extents no longer include an
application-defined composer slot.

Capture action events now have a short pending phase. During that phase the FAB
is disabled, the native sheet exits, and duplicate action events are ignored.
After the handoff deadline, the existing OCaml full editor opens with either an
empty source or the exact staged source. A completed handoff advances the
native key so the next compact Capture session begins empty.

The maintained manifests and lockfiles now select the new bonsai_flutter
revision. Focused OCaml tests, `dune build @all`, source boundaries, host sync,
Flutter analysis and tests, the real-OCaml runtime matrix, macOS Debug, and
unsigned iOS arm64 builds all complete successfully. The controlled iPhoneOS
toolchain reports `bonsai_flutter_ios_sdk 0.1.0~dev.17` and passes ABI
verification.

## Risks

- A native modal route can outlive the logical frame that created its renderer
  children. The two-phase disabled/dismissed handoff prevents navigation from
  deleting those children while the route is active.
- The OCaml timer and Flutter route animation are separate clocks in widget
  tests. Runtime tests must advance both real runtime time and Flutter's fake
  frame clock while waiting.
- The component keeps a transient draft only for its current stable native
  key. Handing the draft to the full editor intentionally advances the key and
  starts the next Capture session empty.
- `bottomNavigationBar` reserves body space rather than overlaying it. Retaining
  the old bottom-clearance slot would create excessive blank space, so the old
  slot and extent role are removed rather than deprecated.
- The expanded surface is a modal route, not an inline width morph. Tests and
  documentation must verify the published component contract rather than the
  superseded exploration.

## Questions

None. Use the published framework-owned
`Ui.Native_widget.Expandable_message_composer` and its Material modal route.
