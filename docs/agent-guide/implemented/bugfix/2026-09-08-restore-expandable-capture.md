# Restore Expandable Capture

## Problem

The uncommitted Journals/Favorites adapter always renders the Capture FAB while
its persistent sheet is open and omits the embedded composer surface treatment.

## Proposal

Restore the original Expandable_message_composer call and native event decoding.
Remove Journal_capture.Native and the Flutter JournalCapture adapter/registration.
Keep root navigation and Favorites behavior. Restore the original action icons,
enabled states, animation configuration, and capture key reset after save.

## Decision

Use the original framework Expandable_message_composer. The user authorized
this restoration and accepted the existing modal/draft behavior on 2026-09-08.

## Alternatives considered

### Repair the persistent adapter

Rejected by the user: preserving the original component is preferred over draft
restoration after tab removal and navigation while a capture sheet is open.

## Acceptance criteria

- Capture uses the framework expandable composer and its existing modal sheet.
- The FAB disappears while the sheet is open; the editor shares its surface.
- Text, task toggle, and save events continue to reach application state.
- Favorites has no Capture. Root navigation behavior remains covered.
- Remove obsolete adapter paths without framework, spec, or dune edits.

## Risks

- Switching destinations after dismissing the sheet removes the native draft.
- The modal sheet blocks bottom navigation until dismissed.

## Consequences

The framework again owns FAB visibility, embedded surface treatment, and modal
sheet lifetime. Favorites remains without Capture; users dismiss the sheet
before switching destinations, and a newly mounted composer starts empty.

## Verification ownership

The production owner of sheet visibility and composer surface is Flutter widget
state. Application.Root_navigation public events own draft and destination state,
but expose no sheet-open event or material surface; Capture_edited and Select
cannot reproduce these rendering defects. Test at the native widget boundary,
without adding duplicate reducer or transport regressions. Adapt existing native
capture coverage to the explicitly accepted modal and draft lifecycle.

## Questions

None. On 2026-09-08 the user explicitly accepted both tradeoffs and requested
restoring Expandable_message_composer. Implementation is authorized.

## Implementation outcome

Restored the original framework composer configuration, icon/button children,
and native Text_changed/Button_pressed decoding. Removed the source prop and
both application adapter definitions, plus the Flutter kind 1002 registration.
Removed obsolete source-boundary exceptions for the custom capture controller.
Root navigation and application draft/save state ownership remain intact.

## Verification

- Before implementation, all four native sheet regressions failed on the
  production adapter: visible FAB and differing surfaces in light/dark themes.
- After restoration, the native root suite passed all 16 tests, including modal
  dismissal, destination removal, keyboard layout, enlarged RTL, and key reset.
- dune build @all and dune runtest passed.
- Flutter analyze passed with no issues.
- Full Flutter tests passed: 156 passed, 7 existing tests skipped.
- Changed OCaml/Dart formatting and git diff --check passed.
- No framework, spec, or dune file was modified for this change.

## Follow-up: missing native registration

The user reported Unsupported native widget kind 7 after restoration. The
application registry still omitted registerExpandableMessageComposer. Direct
widget tests bypassed that registry and did not establish host reachability.
Restore that registration and verify a valid kind-7 descriptor through the public
createJournalWidgetRegistry/build boundary before testing sheet opening.
The application pure reducer has no registry registration or widget construction
event; its public Capture_edited/Select events cannot reproduce this defect.
The narrow production owner is the Flutter application widget registry. Add only
its native regression, without duplicating reducer/transport coverage.

The registry regression failed with an actual UnsupportedNativeWidget before the
registration was restored, then passed through the same public descriptor/build
path and opened the editor. All 17 root native tests passed, Flutter analyze
reported no issues, and bonsai-flutter build macos --profile=debug produced the
updated Debug application successfully.
