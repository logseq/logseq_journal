# Scroll-Responsive Capture FAB

## Problem

The Journal route always presents Capture as an extended floating action button
with an Add icon and the `Capture` label. The button remains fully extended
while the user scrolls down through journal entries, where its width covers more
of the reading surface than is needed to keep the primary action available.

The requested interaction has two resting presentations:

- after sufficient downward travel, Capture becomes a smaller icon-only FAB;
- after sufficient upward travel, it returns to the current extended FAB; and
- small direction changes must not repeatedly toggle the presentation.

The current application already has one keyed vertical `Scroll_view`. Its
`on_scroll` event reports both the current offset and the latest delta, but the
handler is intentionally a no-op. The existing native
`Expandable_message_composer` is the Journal Scaffold's exclusive
`floating_action_button` and only renders `FloatingActionButton.extended`.
Its public OCaml and renderer protocol do not expose an extended-versus-compact
presentation property.

Replacing that component with separate extended and icon-only application
buttons would split the Capture entry point from the native component that owns
the modal sheet, draft, focus, keyboard synchronization, pending state, and
dismissal. The feature therefore needs to preserve one mounted composer while
changing only its collapsed FAB presentation.

This exploration must also preserve the existing FAB-slot decision: Capture
continues to overlay the Scaffold body at `End_float`, the timeline retains its
64-point-plus-bottom-safe-area scroll-content clearance, and no fixed bottom
bar or second floating action is introduced.

## Decision

### Use one presentation state and one composer

Add a required extended/compact presentation property to the published
`bonsai_flutter` `Expandable_message_composer` contract. The host should render
both presentations from the same stateful component and keep the same native
key, controller, focus node, modal route, event IDs, and action children.
Changing the property must not dismiss an open composer, clear its draft,
advance `capture_affordance_key`, or create a second Capture action.

The application should consume a published framework revision and synchronize
the generated Flutter host. It must not hand-edit generated host files, modify
OCaml files in the `bonsai_flutter` repository, or retain the old always-extended
contract as a compatibility branch.

The compact presentation is the standard icon-only FAB: remove the
visible `Capture` label while retaining the existing Add icon, `Open Capture`
tooltip, enabled state, semantic label, and tap behavior. Its smaller width is
the intended reduction; retaining a standard accessible FAB height avoids
turning the primary action into a small target. The transition should animate
width, label opacity, and shape from the trailing edge so Scaffold placement
does not jump. Use the existing application motion duration and curve, and make
the transition immediate when Reduced Motion is enabled.

The label is visually absent only in compact mode. Accessibility continues to
announce `Open Capture`, so an icon-only presentation does not become an
unlabelled button. Tooltip behavior remains available on pointer hover and long
press.

### Accumulate directional travel before toggling

Add transient Journal presentation state containing:

- `Extended` or `Compact` Capture FAB mode; and
- accumulated signed travel for the direction that could cause the next mode
  change.

Use a symmetric threshold of 24 logical pixels in both directions. Process
scroll payloads as follows:

1. Start in `Extended` with zero accumulated travel.
2. While extended, accumulate positive deltas. At `+24`, enter `Compact` and
   reset the accumulator.
3. While compact, accumulate negative deltas. At `-24`, enter `Extended` and
   reset the accumulator.
4. When the delta reverses before reaching the active threshold, discard the
   previous partial travel and begin accumulating in the new direction.
5. Ignore zero deltas. Do not toggle merely because scrolling starts or ends.
6. At the top boundary (`pixels <= 0`), force `Extended` and reset travel.

In Flutter's current scroll payload, positive delta means movement farther down
the scroll content and negative delta means movement back toward the top. The
threshold is based on cumulative travel, not elapsed time, velocity, the
absolute list offset, or one unusually small frame delta. A mouse wheel or
trackpad event may cross the threshold in one update; touch movement normally
crosses it over several updates.

Only a mode transition should produce an observable FAB-presentation update.
Sub-threshold scroll events must not rebuild the native composer with a new key
or alter Capture domain state. The state returns to `Extended` when a new graph
creates a new Journal scroll context. Feed refresh, pagination, row expansion,
and ordinary timeline reconciliation keep the current presentation because
they do not replace that context.

### Keep Capture behavior and scroll geometry unchanged

Both resting presentations open the same modal composer. Direct save,
whitespace rejection, Unicode preservation, duplicate-submission prevention,
Saving semantics, failure retry identity, success dismissal, and draft reset
remain unchanged.

The compact state does not change timeline model records, visible-range
calculation, pagination, scroll anchoring, app-bar collapse, or the existing
end-padding formula. It adds no divider and remains within the project maximum
of three dividers.

Implement the feature test-first. Application tests should drive
signed scroll payloads around the threshold and assert the composer property
without relying only on screenshots. Framework runtime tests should verify
actual extended/compact bounds, animation, Scaffold alignment, semantics, hit
testing, modal continuity, and Reduced Motion. Golden coverage should include
both modes in light, dark, high-contrast, RTL, and large-text environments.

## Alternatives considered

### Toggle on every direction change

The application could compact on the first positive delta and extend on the
first negative delta. This is responsive but makes tiny finger corrections,
trackpad noise, and scroll settling visibly pulse the button. It does not meet
the requested threshold behavior.

### Use absolute scroll offsets

Capture could become compact whenever `pixels` exceeds one fixed offset and
extended only near the top. This is easy to test, but scrolling upward in the
middle of a long journal would not restore the full action as requested. Two
absolute offsets would add hysteresis without representing direction travel.

### Use different down and up thresholds

A larger downward threshold and smaller upward threshold could preserve the
label longer while making Capture return more quickly. The user selected the
same 24-point threshold for both directions, which gives the interaction one
predictable distance and keeps its hysteresis symmetric.

### Render a separate icon-only application FAB

The app could swap `Expandable_message_composer` for a Material icon FAB.
However, the icon FAB cannot invoke the component's private native modal route.
Keeping both mounted or forwarding through a second path would create duplicate
state, event, semantics, and lifecycle ownership.

### Recreate a compact FAB with an empty label

The current native contract requires a non-empty `fab_label`, and an empty or
transparent label would be a layout and accessibility workaround rather than a
real icon-only control. It would also leave ambiguous extended padding.

### Use a 40-point small FAB

`FloatingActionButton.small` makes both width and visual height smaller. It is
more compact, but it requires explicit hit-target treatment and a custom
animated transition from the extended control. The user selected the standard
icon-only FAB so the visual reduction comes from removing the label and excess
width while retaining the current accessible height.

### Hide Capture completely while scrolling down

Removing the FAB maximizes reading space, but it makes the primary creation
action unavailable until an upward gesture and is a materially different
interaction from the requested icon-only state.

## Acceptance criteria

- Capture begins extended at the top of every new Journal scroll context.
- Less than 24 logical pixels of cumulative downward travel leaves the extended
  FAB unchanged; reaching the threshold produces exactly one compact
  transition.
- Less than 24 logical pixels of cumulative upward travel leaves the compact
  FAB unchanged; reaching the threshold produces exactly one extended
  transition.
- Reversing direction before a threshold resets partial travel, so alternating
  small deltas cannot toggle or gradually bank travel across directions.
- Returning to offset zero always restores the extended FAB.
- Compact mode visibly contains only the existing Add icon while retaining the
  `Open Capture` semantic label, tooltip, enabled state, and accessible hit
  target.
- Width, label, and shape transition smoothly from the Scaffold's trailing FAB
  edge with the application motion token; Reduced Motion changes the state
  immediately.
- The same keyed `Expandable_message_composer` remains mounted across both
  presentations and while its modal route is open.
- Both presentations open exactly one unchanged direct-capture composer and
  preserve all save, pending, success, failure, retry, keyboard, and draft
  behavior.
- Capture remains the Scaffold's only `floating_action_button` at `End_float`;
  no bottom bar, body overlay, second FAB, or extra stationary clearance is
  added.
- Journal app-bar collapse, timeline visible ranges, pagination, stable row
  keys, scroll anchoring, and the existing scroll-content end clearance retain
  their current observable behavior.
- Touch, mouse wheel, and trackpad scrolling behave consistently on iOS and
  macOS, including large single-event deltas.
- Light, dark, high-contrast, text-scale 3.2, RTL, and Reduced Motion coverage
  verifies both resting presentations.
- The feature adds no divider and does not modify Dune files, protected `spec/`
  OCaml files, generated host source by hand, or OCaml files in the
  `bonsai_flutter` repository.

## Risks

- Scroll events currently cross the renderer boundary into OCaml even when the
  handler does nothing. Accumulating every frame in the main application state
  could cause avoidable recomputation unless sub-threshold updates remain
  presentation-local or are otherwise kept from rebuilding the composer.
- The current scroll payload does not distinguish touch drag, pointer-signal,
  ballistic, and programmatic movement. The proposed delta policy treats real
  viewport movement consistently; a future programmatic animated scroll would
  also affect the FAB unless the protocol gains a movement-source field.
- Changing the native protocol requires one synchronized published framework
  revision across the OPAM pin, application manifests, SDK package, and Flutter
  host. A mixed revision can make OCaml tests and runtime behavior disagree.
- A compact transition must preserve native widget identity. Replacing the
  widget key can dismiss an open sheet or discard draft state.
- Rapid alternating input near the threshold can still request animations in
  opposite directions after each full threshold is crossed. The native
  animation must reverse from its current value rather than jump or queue.
- A 40-point small visual FAB would need explicit verification that the hit
  target remains accessible on both Apple platforms.

## Questions

None. The user confirmed the standard icon-only FAB and the same 24-logical-pixel
threshold in both directions on 2026-08-25.

## Consequences

- The project is pinned to `bonsai_flutter` revision
  `1755441c24d718206a3d61af0882c0727f810d46` and its dev.22 Apple framework.
  That release provides one-state composer morphing, ordered same-sign scroll
  delta compaction with explicit zero and direction boundaries, and root-level
  locale resolution with RTL directionality.
- Journal owns only the transient `Extended` or `Compact` presentation and its
  signed travel accumulator. The symmetric threshold is 24 logical pixels,
  reversal discards partial travel, offset zero forces `Extended`, and changing
  graphs creates a fresh extended scroll context.
- The native composer retains one key, modal route, controller, focus node,
  draft, event identity, semantic label, tooltip, and save lifecycle while its
  width and label animate between the two resting presentations. Reduced Motion
  settles the presentation immediately.
- Runtime coverage exercises consecutive scroll deltas without timing gaps,
  interruptible presentation changes, open-composer continuity, RTL trailing
  placement, text scale 3.2, high contrast, Reduced Motion, and all six Capture
  golden states.
- The implementation preserves the existing Scaffold FAB slot, timeline
  clearance, timeline behavior, and divider count. It does not change Dune
  files, protected `spec/` OCaml files, generated host source by hand, or OCaml
  files in the `bonsai_flutter` repository.
