# Native iPhone Accessibility Traits

## Problem

Physical acceptance currently observes only the user's normal Dynamic Type size.
Six toolbar audit findings remain unresolved. Changing global device preferences
would interfere with the user's other applications. We need bounded evidence of
production view behavior at accessibility sizes on the connected iPhone.

## Decision

Add an explicit optional large-text mode to the isolated acceptance host only.
Use the public UIKit window trait override to supply the largest accessibility
content-size category. Expose the inherited SwiftUI size in a host-only
accessibility status element. An initial SwiftUI-only environment experiment
scaled Journal but did not reach separately presented sheets, so it is retained
as insufficient evidence and replaced by the window-level input. Preserve
the unmodified environment when the option is absent. Retain the same production
runtime and views. Exercise Journal, Capture, Block/Append, Settings and
Diagnostics with real UIKit navigation, keyboard and rotation. Compare screenshots
and accessible control reachability. Record any limits of the scoped window input;
this does not establish device-wide preferences or large-content viewer support.

## Alternatives considered

### Change device-wide accessibility preferences

Not selected for this controlled acceptance because unrelated user applications
would also change. Actual system preference and VoiceOver behavior remain separate
gates and cannot be replaced by this scoped input.

### Treat the automated audit as conclusive

Not selected because native-only toolbar controls reproduce the same warning.
Screenshots and actual operations provide different, necessary evidence.

## Acceptance criteria

- The opt-in host reports accessibility5 through the inherited SwiftUI environment.
- Real production views execute on iPhone at the selected size; collect layout,
  navigation, composer input/rotation and reachable controls, retaining failures.
- No global system preferences, user graphs, production UI/runtime, Dune, protected
  spec files or SDK sources change.
- Keep source, binary hashes and run results, clearly distinguishing controlled
  traits from system accessibility and VoiceOver acceptance.

## Consequences

The optional window-trait mode builds, signs and runs on the physical iPhone.
Its inherited SwiftUI readout reports accessibility5. Journal, Block, Settings
and Diagnostics visibly scale and reflow; navigation, composer input/rotation,
density selection/restoration and final form rows have retained device evidence.
A normal launch restores standard typography without global setting changes.

The earlier SwiftUI-only input did not reach separately presented sheets and is
retained as insufficient evidence. The final window input exposes a separate
Capture editor font-size discrepancy: the title scales but editor text remains
near normal size. Its UIKit font path requires further investigation; this
acceptance implementation does not claim to solve that production requirement.
The broader UI proposal remains open. See batch 37 of the
[implementation ledger](../../../test-reports/2026-09-16-native-swiftui-standardization/implementation.md).

## Risks

- A scoped window trait does not prove every system accessibility behavior.
- The test host's own status area affects available space and is not production UI.
- An acceptance failure may expose a separate production defect requiring its own
  ownership analysis and decision before implementation.

## Questions

- None. This is bounded acceptance within the authorized iPhone UI task.
