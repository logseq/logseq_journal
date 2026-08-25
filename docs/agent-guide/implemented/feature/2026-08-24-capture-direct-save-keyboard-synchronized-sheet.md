# Capture Direct Save Keyboard Synchronized Sheet

## Problem

The current compact Capture flow has two visible startup phases. Activating the
`Capture` extended FAB first animates a Material modal bottom sheet into place.
Only after the 180 ms route transition completes does the framework request
text-field focus, which then presents the iOS keyboard and moves the sheet above
the keyboard inset. The sequence feels like three separate layout operations:

1. present the bottom sheet;
2. present the keyboard; and
3. move the sheet to its keyboard-safe position.

The delay is intentional in the implemented design: deferring focus avoids
changing the sheet geometry target during its entrance. It is now contrary to
the desired interaction. The sheet and keyboard should begin appearing as one
coordinated response to the Capture tap, with the text field ready sooner.

The expanded composer also contains two actions. Its leading `+` action opens
an empty full Capture editor, while its trailing action transfers entered text
to that editor. The full editor then requires another explicit Save action. For
the primary use case, this makes a one-block capture cross two modal surfaces
and two actions before persistence.

The desired product flow is narrower:

```text
Capture FAB
  -> composer and keyboard appear together
  -> enter text
  -> Save
  -> journal block is persisted directly
```

There should be no leading `+` action and no transition to the full Capture
editor. Removing that editor from the Capture flow also removes its current
task-state and direct-child authoring controls, discard confirmation, Saving
surface, retry surface, and route-owned mutation state. Direct save therefore
needs an explicit replacement contract for mutation admission, success,
failure, retry, draft ownership, and duplicate-tap prevention.

The installed
`Ui.Native_widget.Expandable_message_composer` cannot yet express the complete
target interaction. Its Flutter implementation creates
`ModalBottomSheetRoute` with `requestFocus:false` and requests focus only when
the route animation reports `completed`. Its action API can represent a single
trailing Save button, but application prop changes do not provide an expanded
route-local Saving/error surface. Any framework change must be published in
bonsai_flutter and consumed through a pinned revision; generated
`.bonsai-flutter` files are not source edit targets.

## Proposal

Use a direct-save mode for
`Ui.Native_widget.Expandable_message_composer` with one coordinated opening
transition and one trailing Save action.

### Coordinate sheet entrance and keyboard presentation

Request editor focus in the first mounted sheet frame instead of waiting for
the modal route to complete. The keyboard request and sheet entrance should
therefore begin from the same Capture activation. The sheet must continuously
follow `MediaQuery.viewInsets.bottom` during both animations so it never first
settles at the safe-area bottom and then jumps to the keyboard-safe position.

The user confirmed one 180 ms opening transition rather than two sequential
stages. From the Capture tap, sheet entrance, focus, iOS keyboard presentation,
and keyboard-inset following share the same animation window. The keyboard
finishing its presentation marks the end of the entire opening transition; the
sheet must not then start another 180 ms inset animation. In particular, a live
keyboard inset must be followed directly or by the same coordinated progress,
not passed through a second independent `AnimatedPadding` duration.

This is a framework-owned interaction. The application should continue to send
motion intent and must not add an application timer that guesses when to focus.
The framework implementation should test the actual intermediate frames on
iOS-sized view metrics. Reduced Motion should still reach the focused,
keyboard-safe final state without an artificial delay.

The standard duration remains 180 ms. Reduced Motion still uses no staged
motion, while preserving the same mounted, focused, and keyboard-safe result.

### Expose one Save action

Remove the leading `+` button from the component configuration. Configure one
trailing filled action with the accessible label `Save journal block`. It is
hidden or disabled for trimmed-empty text and emits the exact untrimmed UTF-8
source when activated. Pressing the software keyboard action must not create a
second, different save path unless it is explicitly selected as equivalent to
the visible Save action.

The component must prevent double submission while one capture mutation is in
flight. The current full-editor labels and action IDs, including `Open full
Capture editor`, `Continue Capture`, and `journal-capture-composer-plus`, become
obsolete and should be removed rather than retained as compatibility aliases.

The user confirmed that the software keyboard Done action is not Save. Done may
end editing and dismiss the keyboard, but it must leave the composer sheet and
draft intact and must not admit a graph mutation. The visible trailing Save
action is the only direct-capture submission path.

### Persist directly from the Journal route

Replace `capture_launch` and its delayed full-editor route handoff with a
Journal-route-owned pending direct capture. On Save, OCaml should:

1. reject trimmed-empty source;
2. snapshot the exact source from the native button event;
3. allocate mutation, block, sibling-order, and creation-time identity using
   the existing Capture domain helpers;
4. construct a top-level `Journal_graph_request.Capture` directly; and
5. admit at most one request until the graph response resolves.

`Block_captured` must reconcile this pending direct capture even though
`Journal_routes.capture` no longer exists. Success prepends the returned
timeline entry through the existing projection path, clears the pending state,
and advances the native component key so the next draft starts empty. Failure
must preserve both the exact request and draft so retry cannot allocate a
different logical capture or silently lose user input.

The user confirmed that every direct Capture creates a plain top-level block
with `Journal_model.No_status` and no children. Removing the full Capture editor
therefore intentionally removes task-state selection and direct-child creation
from the Capture flow; neither capability receives a hidden fallback entry
point.

The user confirmed that Save keeps the composer sheet open until persistence
completes. While the request is pending, the editor and Save action are disabled
and the sheet exposes an accessible `Saving journal block` state. Success
inserts the timeline entry, dismisses the sheet, clears the draft by advancing
the native key, and restores the enabled Capture FAB. Failure leaves the sheet
open, reports the error immediately, and automatically returns to an editable,
focused composer containing the exact draft. There is no separate Retry or
Reopen action. The existing Save action becomes available again and remains the
only submission path.

Because the failure surface permits further editing, direct-capture state must
distinguish an unchanged retry from a revised capture intent. Re-saving the
unchanged draft reuses the admitted request and mutation identity. Editing the
restored draft first ends that failed attempt and prepares a new request only
after the runtime has classified the prior outcome as terminal; an unknown
commit outcome must never be converted silently into a new mutation identity.

### Remove the full Capture editor path

If direct save replaces every creation use case, remove the Capture editor page
and its navigation state rather than leaving an unreachable route. This
includes its text editor, task toggle, child editors, dirty-discard dialog,
Saving/Failed/Retry presentation, `capture_launch` timer, and action dispatch
branches. Retain reusable Capture domain logic only where direct mutation
admission still needs it; simplify or remove obsolete route-shaped state.

Detail editing is outside this proposal. Existing graph mutation,
pagination, timeline insertion, authentication, Material theme, bottom
navigation, safe-area, and at-most-three-divider decisions remain in force.

## Decision

Implement direct Capture with the published bonsai_flutter revision
`d182690aeaa82ad0a972756205c62e3b598e3c24`. The framework-owned expandable
composer requests focus in its first mounted sheet frame, follows keyboard
insets directly without a second `AnimatedPadding` transition, and remains
mounted when application props disable it during persistence.

The Journal route owns one pending direct-capture request and exposes exactly
one trailing Save action. A save creates one top-level `No_status` block with
no children, preserves exact source and mutation identity across an unchanged
retry, closes only after success, and restores the focused draft with an error
after failure. Remove the full Capture editor, its route and handoff timer, and
all obsolete actions instead of retaining a fallback path.

## Alternatives considered

### Keep focus deferred until route completion but shorten the duration

This reduces the pause but preserves the same sequential sheet-then-keyboard
behavior. It does not meet the requirement that sheet and keyboard presentation
start together.

### Autofocus before mounting the modal route

A focus request cannot target an editor that is not mounted. Attempting it from
the collapsed FAB state risks a lost request or keyboard presentation without a
valid text-input client. The earliest valid point is the first mounted sheet
frame.

### Keep the full editor but rename Continue to Save

This would disguise navigation as persistence and retain the second modal,
handoff delay, and second Save action. It does not simplify the Capture flow.

### Save optimistically without pending mutation state

Closing and clearing the native draft immediately is visually simple, but a
transport or graph failure would lose the only copy of the text and retry could
allocate a duplicate mutation. Direct capture still requires explicit OCaml
pending state and idempotent retry ownership.

### Dismiss immediately after admitting the save

This minimizes the perceived submit time, but hides whether persistence has
completed and forces failures to restore or reopen a previously dismissed
surface. It is rejected because the user selected close-on-success behavior.

### Keep the full editor only for task state and children

This preserves advanced creation features behind another action, but it keeps
the `+`/full-editor branch the requested flow explicitly removes. If task or
child creation remains a product requirement, it needs a separate future entry
point rather than a compatibility branch inside compact Capture.

## Acceptance criteria

- One tap on the resting `Capture` FAB mounts the composer, requests focus, and
  begins iOS keyboard presentation in the first mounted sheet frame.
- Runtime tests observe no completed safe-area-only sheet state between the FAB
  tap and the keyboard-moving sheet; sheet position follows the changing
  keyboard inset without overflow, jump, or second delayed animation.
- The standard Capture opening has one 180 ms total animation window. Keyboard
  completion and the final keyboard-safe sheet position complete that same
  transition, with no additional inset animation afterward.
- The expanded composer contains exactly one Save action and no `+`, Open full
  Capture, or Continue Capture action.
- Save is unavailable for trimmed-empty input and sends non-empty Unicode text
  byte-for-byte without trimming it.
- The software keyboard Done action does not save, clear, or dismiss the sheet;
  it only ends keyboard editing while preserving the draft. The visible Save
  action is the sole mutation trigger.
- Save admits one and only one `Journal_graph_request.Capture`; repeated taps
  while pending cannot create duplicate blocks.
- After Save, the sheet remains mounted with its editor and Save action disabled
  and exposes an accessible Saving state until the graph response resolves.
- A successful response inserts the new top-level block into the existing
  timeline, then dismisses the composer, clears the draft, and restores the
  enabled Capture FAB.
- A failed response keeps the sheet open, reports an accessible error, restores
  and focuses the exact editable draft automatically, and re-enables the
  existing Save action. No separate Retry or Reopen action is rendered.
- Saving an unchanged restored draft reuses its admitted request and mutation
  identity. Editing after failure cannot allocate a new identity until the
  previous outcome is known to be terminal.
- No Capture action opens a full Capture editor. Its page, route, actions,
  discard confirmation, and delayed `capture_launch` handoff are absent from
  production and tests.
- Every direct Capture creates a top-level `No_status` block with no children,
  and there is no hidden or unreachable compatibility path for the removed
  task-state or child-authoring controls.
- Existing swipe/scrim/Escape dismissal, draft restoration, Safe Area, large
  text, RTL, keyboard, disabled semantics, timeline geometry, and divider-limit
  contracts remain covered.
- Light, dark, high-contrast, Reduced Motion, macOS, and iOS verification cover
  both the coordinated opening and direct-save lifecycle.

## Consequences

Capture now moves from its resting FAB directly to one modal composer and one
persistence action. The keyboard focus request starts with sheet entrance, and
each changing keyboard inset becomes the sheet's current layout target rather
than starting another 180 ms application animation.

The compact composer remains visible but inert while a graph request is
pending. Successful persistence advances the native widget key and removes the
sheet; failed persistence keeps the same key and draft, reports the error, and
re-enables and refocuses the editor. An unchanged retry reuses the admitted
request, while the first edit after failure ends that failed attempt.

Capture-time task selection, child authoring, dirty-discard confirmation, and
the full-editor retry surface no longer exist. The maintained opam manifests
and lockfiles pin bonsai_flutter revision
`d182690aeaa82ad0a972756205c62e3b598e3c24`, whose iOS SDK repository is
published as `0.1.0~dev.18`. Framework tests and analysis, OCaml build and
tests, pinned Flutter analysis and real-runtime tests, macOS Debug, and
unsigned iOS arm64 builds all pass.

## Risks

- Requesting focus during the sheet entrance means keyboard insets can change
  the route geometry while it is animating. Incorrect coordination can produce
  a jump, overshoot, clipped composer, or two competing animations.
- iOS keyboard startup is controlled by the operating system. The application
  can require same-frame focus intent, one 180 ms logical transition, and
  continuous inset following, but device verification must detect if physical
  keyboard timing diverges instead of masking it with a second app animation.
- Removing the full editor removes Capture-time task-state selection and direct
  child creation unless those capabilities receive another entry point.
- Keeping the sheet open until confirmation makes persistence state explicit
  but can feel slower on a high-latency graph operation. It also requires
  framework support for route-local disabled, Saving, and error presentation.
- The direct capture must retain mutation identity across retry. Rebuilding a
  request from source after failure can duplicate a block if the first outcome
  was committed but its response was lost.
- Clearing or changing the native component key before success can destroy the
  only local draft. Leaving it unchanged after success can accidentally restore
  already-saved text.
- Removing route-shaped Capture state may affect tests and response handlers
  that currently use route presence to recognize `Block_captured` ownership.

## Questions

None. The user confirmed the direct-capture shape, close-on-success behavior,
automatic editable-draft restoration on failure, one 180 ms coordinated
opening, and keyboard Done behavior.
