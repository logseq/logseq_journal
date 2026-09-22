# E2EE Unlock Redesign

## Problem

The unlock page presents a sparse grouped settings form with repeated password
labels, no selected graph context and a toolbar-only confirmation action. Errors
appear in a detached section. This makes the primary task difficult to scan and
provides weak visual hierarchy, particularly on iPhone with its keyboard visible.

## Decision

Replace the unlock form with a focused native SwiftUI page: a restrained lock
symbol, a clear heading, selected graph name when known, concise password guidance,
a labeled secure field, adjacent recovery feedback, a prominent in-content Unlock
button and a secondary Choose another graph action. Keep Diagnostics in the toolbar.
Use semantic fonts, system colors, a bounded readable width and scrollable content
that respects keyboard safe areas. No decorative gradients, custom text editor,
password reveal feature or new authentication state machine is required.

Retain the existing OCaml password editor session, input validation, submit and
cancel handlers. A dedicated native layout composes the same OCaml-owned controls;
no password is passed through native widget properties. Error and normal states
keep the same editor slot and identity. Graph name comes from the current selected
catalog item and is omitted if unavailable, without displaying a raw UUID.

## Alternatives considered

### Restyle the existing grouped Form

Rejected: a single-field unlock task benefits from one clear action area rather
than settings sections and duplicated toolbar labels.

### Own password state in a separate SwiftUI authentication form

Rejected: it would duplicate the application session and submission owner and
risk losing the recently repaired native focus behavior.

## Acceptance criteria

- The active graph name is visible when known; absent catalog data remains clear.
- The primary Unlock action is adjacent to the field and disabled for empty input.
- Failure feedback is adjacent to the field and remains accessible without color.
- Choose another graph invokes the existing cancellation action without submitting.
- Native layout is reviewed in narrow, wide, dark and large-text configurations;
  long names/errors wrap, controls remain reachable and no divider is required.
- Existing dispatch/editor tests and macOS/iOS builds pass. Physical iPhone keyboard
  and VoiceOver checks remain explicitly pending while the phone is unavailable.
- No Dune or protected spec files change; Undo/Redo remains deferred.

## Consequences

The unlock page now has a single in-content primary action and explicit graph
context. Native SwiftUI composes the existing secure input and OCaml commands;
authentication ownership and password lifetime are unchanged. Visual acceptance
uses an isolated shared-layout preview instead of a real user account. The new
layout is included in the production host and warm-start acceptance host.

## Risks

- Native child identity must stay stable across edits and error changes.
- Visual previews with standard SwiftUI fields validate layout only; native Journal
  bridging and secure editing retain their existing regression coverage.

## Questions

- None. The user requested a complete review, redesign and implementation of this UI.

## Validation

The expanded existing application presentation test fails before implementation
on missing graph context and passes afterward for known/absent names and both
initial/error states. The complete application dispatch suite and OCaml formatting
checks pass. Current macOS and iPhoneOS complete objects verify successfully;
macOS Debug and unsigned iOS Release full application builds pass.

The shared native layout was visually inspected in narrow/wide macOS windows and
an iPhone 13 Simulator for keyboard-visible, dark, long-content, accessibility3
and right-to-left configurations. Controls and long feedback wrap and remain in
the scrollable content. Source hashes, logs and precise preview limitations are
in `docs/test-reports/2026-09-17-e2ee-unlock-redesign/`. Physical iPhone keyboard
and VoiceOver speech acceptance remain pending device availability.
