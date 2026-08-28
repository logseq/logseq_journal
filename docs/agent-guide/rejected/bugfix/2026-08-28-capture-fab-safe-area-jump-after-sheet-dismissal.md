# Capture FAB Safe Area Jump After Sheet Dismissal

## Problem

On an iPhone with a non-zero bottom Safe Area, dismissing the direct Capture
composer can briefly render the restored Capture floating action button too
close to the physical bottom edge. The button then jumps upward into its normal
`End_float` position instead of appearing there initially.

The application mounts one
`Ui.Native_widget.Expandable_message_composer` as the Journal Scaffold's
exclusive floating action button. The application does not own the modal route
or its dismissal timing. The synchronized bonsai_flutter native widget owns both
states:

- while `_sheetRoute` is non-null, its Scaffold child is
  `SizedBox.shrink()`;
- `_dismissSheet()` unfocuses the editor and immediately pops the route; and
- when the route's 180 ms reverse animation completes, `whenComplete` clears
  `_sheetRoute`, so the FAB is rebuilt immediately; and
- after a successful save, `Block_captured` advances the native widget key to
  clear the draft. The old native State disposes, immediately removes its active
  route, and the replacement State builds a fresh FAB in the same application
  update.

The successful key replacement is the strongest reproduction because it does
not wait for route reversal at all. Ordinary Escape, scrim, and drag dismissal
can produce the same ordering when the route completes before the iOS keyboard
finishes its longer hide animation. In either path, the restored FAB is laid out
by the Journal Scaffold while the root `MediaQuery.viewInsets.bottom` is still
positive.
Flutter Scaffold defaults `resizeToAvoidBottomInset` to `true` and derives the
FAB geometry as follows:

- `minInsets.bottom` is the current keyboard inset;
- `minViewPadding.bottom` is forced to zero for every positive keyboard inset;
- `End_float` places the FAB above `contentBottom` with the standard 16-point
  floating margin; and
- when the keyboard inset becomes exactly zero, Scaffold restores the full
  bottom `viewPadding` in one frame.

For an iPhone with a 34-point bottom Safe Area, a final positive keyboard inset
of one point puts the FAB approximately 17 points above the physical edge. At
zero inset, the restored Safe Area plus the floating margin puts it 50 points
above the edge. That discontinuous branch produces an approximately 33-point
upward jump on the last keyboard frame. This explains why the issue is visible
on Safe Area devices and why the button first appears at the bottom rather than
at its stable resting position.

Existing coverage verifies the sheet surface while keyboard insets change and
verifies the final collapsed FAB after `pumpAndSettle`. It does not sample FAB
geometry between route completion and the final zero-inset keyboard frame, so
the transient invalid placement is currently invisible to tests.

## Proposal

Fix collapsed placement in bonsai_flutter's `ExpandableMessageComposer`, then
publish, pin, and synchronize that framework revision into this application.
Do not paint or expose the collapsed FAB while the inherited bottom keyboard
inset is positive. This rule covers both a same-State route completion and the
fresh State created by the successful-save key advance. Because the build reads
`MediaQuery.viewInsets.bottom`, the first zero-inset metrics frame rebuilds the
component and lets Scaffold lay out the FAB directly at its stable Safe
Area-aware `End_float` position.

The gate must not clear the controller, change the native key, emit an event, or
create a second Capture action. A zero-inset collapsed build must continue to
render immediately, including Escape, scrim, and drag dismissal without an
active text-input client. Reduced Motion may remove route animation, but it must
not bypass the zero-inset placement gate when a keyboard is still hiding.

Add framework widget coverage for both lifecycle paths. One test drives the
route to completion while supplying a sequence of decreasing positive bottom
view insets. A second replaces the keyed composer while the route and keyboard
are present, matching successful Capture reset. Assert that no FAB is painted
or hit-testable during intermediate positive-inset frames and that its first
painted bounds at zero inset already include the device bottom Safe Area and
standard Scaffold margin. Retain existing tests for final geometry, draft
preservation, repeated expansion, disabled state, RTL, large text, and all
dismissal gestures.

The application should only consume the published framework result through its
normal pin and generated-host synchronization workflow. Do not hand-edit
`.bonsai-flutter`, add an application compatibility wrapper, add a second FAB,
or alter the OCaml Capture state machine.

## Questions

- Should implementation proceed as the recommended bonsai_flutter native-widget
  lifecycle fix followed by a published pin/sync in this repository, accepting
  the brief no-FAB interval while the keyboard finishes hiding?

## Acceptance criteria

- On a viewport with a 34-point bottom Safe Area, dismissing Capture while the
  keyboard inset decreases through positive values never paints or exposes a
  hit-testable Capture FAB at an unsafe transient y-position.
- The first restored FAB frame occurs with a zero keyboard inset and already
  has the same bounds as a cold collapsed Journal screen.
- Route reversal and keyboard dismissal remain concurrent; the sheet is not
  kept visible merely to wait for the keyboard.
- Dismissal with no visible keyboard restores the FAB without an additional
  frame delay that is observable under disabled animations.
- Success key replacement, Escape, scrim tap, and downward drag all obey the
  same placement gate.
- Exact draft preservation, save admission, pending-state suppression, failure
  restoration, success reset, and stable native key semantics remain unchanged.
- RTL, text scale 3.2, high contrast, Reduced Motion, macOS, iOS, and zero Safe
  Area layouts do not regress.
- The application pins and synchronizes one published bonsai_flutter revision;
  no generated host edit, compatibility path, second FAB, Dune edit, `spec/`
  OCaml edit, or bonsai_flutter OCaml edit is introduced.
- No divider is added, keeping the application within the three-divider limit.

## Risks

- There can be a short interval after the sheet route disappears and before the
  keyboard reaches zero inset in which no Capture control is visible. This is
  intentional: any FAB displayed in that interval would either move with the
  keyboard or require duplicating Scaffold layout policy.
- The implementation should rely on the inherited `MediaQuery` dependency and
  must not retain a popped route, FocusNode, BuildContext, or manual metrics
  observer after disposal.
- An unrelated persistent keyboard also gives the collapsed component a
  positive inset, so Capture remains hidden until that keyboard closes. This is
  a deliberate trade-off to avoid presenting the component in a moving or
  unsafe Scaffold position.
- Interactive keyboard dismissal can pause at a positive inset. If the route
  has already completed, Capture remains hidden until the system finishes
  dismissal; tests must cover cancellation and completion behavior explicitly.
- Publishing and synchronizing a framework fix affects every application using
  `ExpandableMessageComposer`, so its framework tests must cover all dismissal
  modes before this repository updates its pin.

## Alternatives considered

### Disable Scaffold keyboard resizing in the application

Setting the Journal Scaffold's `resizeToAvoidBottomInset` to `false` would keep
its FAB geometry based on `viewPadding` while the modal keyboard hides. The
current OCaml Material Scaffold contract does not expose that property, so this
would require a protocol and renderer surface expansion for a workaround to one
native widget's route lifecycle. It would also change Journal body resizing for
every future keyboard interaction. The component that hides and restores the
FAB has enough information to avoid exposing the invalid intermediate state.

### Pop the sheet only after the keyboard is fully hidden

Unfocus first, wait for a zero inset, and then start the 180 ms route reverse
animation. This avoids the FAB jump, but serializes keyboard dismissal and sheet
dismissal, lengthening the interaction and making the sheet remain visible
after the user asked to close it. The route and keyboard animations can remain
concurrent; only restoration of the background FAB needs to wait.

### Keep the FAB mounted behind the modal route

Leaving the FAB mounted preserves its State but does not fix Scaffold geometry.
It still follows the positive keyboard inset and still crosses Flutter's
discontinuous Safe Area branch. If the modal route becomes transparent or
completes early, the invalid position remains observable, and hidden semantics
or hit testing would require additional suppression.

### Preserve the native key after successful persistence

The application currently advances the key to atomically dismiss the route,
dispose the old controller, clear the successful draft, and restore a clean
component. Keeping the key would leave the successful sheet mounted because the
native contract has no separate reset-and-dismiss property. Adding that property
would expand the OCaml protocol and lifecycle surface for behavior that a
collapsed positive-inset render gate can handle without changing Capture state.

### Match the route reverse duration to the keyboard

A longer fixed reverse duration may hide the problem on one iOS release, but
keyboard duration varies by platform, input method, accessibility settings,
interactive dismissal, and Reduced Motion. Timing coincidence is not a layout
contract.

### Add compensating padding or translation to the FAB

The child could attempt to cancel Scaffold's changing offset near the final
Safe Area threshold. That duplicates private Flutter Scaffold placement math,
including bottom bars, snackbars, RTL, and future framework changes. Hiding the
FAB for the short interval in which its stable position is unknowable is
smaller and preserves Scaffold ownership.

## Rejection reason

The defect is owned by bonsai_flutter's ExpandableMessageComposer lifecycle and must be fixed and verified in that repository rather than in logseq_journal.
