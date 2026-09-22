# Diagnose Native List Reentrancy

## Problem

The batch 42 macOS isolated host logs two NSTableView delegate reentrancy
warnings during initial Journal presentation. AppKit says this warning will
become an assertion. Successful navigation does not establish that native
collection updates obey the platform lifecycle.

## Proposal

Reproduce the warning on the current isolated macOS host and capture its native
call stack before changing production code. Determine whether application
visibility/event delivery, SDK rendering, or SwiftUI owns the reentrant update.
First assess the public pure application boundary; a platform delegate warning
cannot be reproduced by injecting an incorrect visibility result into a reducer.
If the defect requires native layout, keep regression coverage at that boundary.
Choose the smallest owner-level repair only after the call stack establishes it.
Preserve retained-list navigation, pagination and explicit Capture scrolling.

## Questions

- None. Investigation follows the user's request to continue on macOS.

## Batch 43 evidence

Five captured warning stacks show recursive AppKit row-span caching during
SwiftUI OutlineListCoordinator endUpdates, triggered while scrolling. This
refines the initial startup-only timing assumption. Application event callbacks
are absent from that synchronous stack, but earlier renderer updates remain a
possible trigger. Two public SwiftUI-only controls do not reproduce the warning;
upstream-only ownership is not established. Production code remains unchanged.

See `docs/test-reports/2026-09-16-native-swiftui-standardization/batch43-native-list-reentrancy.md`.
Next compare fixed and updating properties in the same SDK-hosted native widget,
with property/visibility/child revision timestamps. Keep this decision proposed;
no fix or regression owner has been established yet.

## Batch 44 evidence

One warning occurs during a 65-to-100-item pagination update, after binding new
properties but before Resource installation. The first 64 child identities remain
stable. Suppressing visibility event delivery keeps the same host at 65 items and
produces no warning during the bounded scroll control. This narrows the trigger
to live updates in these runs without attributing the production owner. No
production change was made; scratch instrumentation was removed after use.

See `docs/test-reports/2026-09-16-native-swiftui-standardization/batch44-native-list-update-timing.md`.
The decision remains proposed pending a narrow owner-level reproduction.

## Batch 45 evidence

Matched static SwiftUI labels reproduce six warnings inside the full host,
without any RenderNodeState-backed label children. Adding a full-width frame
still produces two warnings. The original dynamic labels produce four, including
unchanged row properties before and after pagination. Neither dynamic children
nor a row-count change is necessary for this reproduction. An expanded standalone
SwiftUI control completes pagination without warning, so upstream-only ownership
remains unproven. Inspect ancestor rendering and presentation/commit transitions
next. Production source is unchanged; scratch controls were removed after use.

See `docs/test-reports/2026-09-16-native-swiftui-standardization/batch45-native-list-label-controls.md`.

## Batch 46 evidence

Scratch SDK instrumentation confirms warnings after binding-only commits: list
properties and child identities remain unchanged while generation-bound callbacks
and presentation admission refresh. Separating display inputs from interaction
context still warns on pagination and is not adopted. Independent SwiftUI controls
with swipeActions, NavigationStack and Chrome-style geometry remain negative.
Investigate native presentation acknowledgment/layout timing next without bypassing
stale-event admission. Production and installed SDK source remain unchanged.

See `docs/test-reports/2026-09-16-native-swiftui-standardization/batch46-native-list-binding-commits.md`.

## Batch 47 evidence

All four captured warnings precede the corresponding PresentationProbe.layout
and acknowledgment callback, with the previous callback already finished.
Synchronous acknowledgment recursion is not supported by these observations.
A standalone control using array items, String IDs and an optional Section header
still completes pagination without warning. A further mixed body/continuation-row
ForEach control compiles but remains unexecuted because the Mac locked. Manual
unlock is requested; diagnostic processes are closed and scratch sources restored.

See `docs/test-reports/2026-09-16-native-swiftui-standardization/batch47-presentation-layout-order.md`.

## User-directed stopping point

On 2026-09-18, the prepared mixed-row standalone SwiftUI control reproduces three
warnings while scrolling and paging to 100 roots, without Journal or the SDK.
The user then explicitly asks not to fix overly fine-grained issues. Stop this
investigation, retain its evidence and prioritize core UI flows. No candidate
fix is promoted to production and the warning is not claimed resolved. The
diagnostic app is closed; the production list-retention behavior is unchanged.

## Acceptance criteria

- Reproduce and retain the native warning and attributed stack on the current build.
- Establish the narrow production owner before choosing a regression or fix.
- If repair is warranted and possible within public interfaces, verify the same
  native scenario without the warning and preserve navigation/pagination checks.
- If it is an upstream limitation, document evidence and the remaining constraint;
  do not claim completion or add an unproven application workaround.
- Do not operate the withdrawn iPhone or alter deferred system accessibility settings.

## Risks

- Debugger attachment changes timing; an absent warning under a debugger alone
  does not prove a repair.
- SwiftUI can perform internal deferred layout; a platform frame is not by itself
  proof that the application or SDK caused the operation.

## Alternatives considered

### Ignore the warning after successful navigation

Rejected: current visual success does not establish safe delegate execution.

### Add an arbitrary delay to all list updates

Rejected: this does not identify the reentrant owner and could delay input or
pagination without fixing lifecycle ordering.

## Rejection reason

The user deferred overly fine-grained fixes on 2026-09-18; preserve the diagnostic evidence and prioritize core native UI flows.
