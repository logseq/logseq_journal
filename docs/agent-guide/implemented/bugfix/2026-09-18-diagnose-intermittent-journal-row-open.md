# Diagnose Intermittent Journal Row Open

## Problem

Batch 54's first middle-row navigation test taps visible row 0055, but no detail
appears within five seconds. The unchanged rerun passes both detail/Back cycles.
The failed row remains at y=426.7, height=52.3; the pinned header is at y=198.3,
height=40.3. Neither a header overlap nor a stale event context is established.

## Decision

Run the existing physical native navigation regression against an isolated host
with temporary action-only diagnostics. Record native Button entry, public event
admission and emit results in the disposable app's Documents directory. Distinguish
missing native activation from rejected admission and downstream navigation.
Keep production sources unchanged until this evidence establishes a defect owner.
Restore the scratch source and rebuild the host after diagnosis.

The public Application route reducer already covers open/completion/Back; its
state cannot express SwiftUI hit testing or native context generations. Existing
pure tests cannot reproduce a tap that never reaches this boundary. Do not add a
second regression layer or inject a false external result. Reuse the actual native
navigation regression that failed in batch 54. Any implementation follows the
observed failing boundary and retains SDK admission fences.

## Alternatives considered

### Retry taps or relax native admission

Rejected: a passing retry does not explain the initial failure and weakening the
lifetime fence may deliver actions to a disposed or unrelated route.

### Add scroll restoration

Rejected: the user explicitly chose retaining the native list UI. This failure
occurs before detail opens, not when returning to the retained list.

## Acceptance criteria

- Preserve the original failure and collect callback/admission evidence on bounded runs.
- Record whether the instrumented runs reproduce the failure; do not label non-reproduction a fix.
- If a fix is justified, reproduce at its public owner before implementation and rerun that regression.
- Restore temporary diagnostics and leave production free of action logs.
- Keep passwords and production user data out of diagnostics.

## Risks

- Instrumentation can change timing, so an instrumented pass alone cannot close the intermittent observation.
- XCTest activation may differ from a human touch; retained screenshots and event logs must be interpreted together.

## Questions

- None. The existing iPhone acceptance authorization covers isolated diagnostic runs.

## Diagnostic refinement

The first two instrumented middle-row runs pass; all four Button callbacks are
admitted and their emissions succeed. This does not explain batch 54's failure.
Check the public native hit-testing boundary next: tap the trailing blank space
inside a visible Journal or Favorites row, below y=510 to avoid the observed
floating system control. Keep the existing navigation assertions. A failure
without a Button callback would isolate a native touch-region issue; do not
assume this explains the earlier center tap without evidence.

## Confirmed native hit-region defect and implementation decision

Both trailing-space tests fail before implementation. Journal taps row 0039 at
(351, 520.2); Favorites taps row 0040 at approximately (351, 519.8). Screenshots
show blank trailing content at these points, above the floating system control.
The Journal action log has no new Button callback. Existing center taps succeed,
and the production Application public-event dispatch suite passes. Native
SwiftUI Button hit testing is the narrowest reproducing owner; no pure reducer
can express this missing touch activation. Keep the two cases in the existing
native navigation suite, without duplicate reducer or SDK tests.

Expand each plain Button label to the available width with leading alignment and
apply a rectangular interaction content shape inside the label. Retain native
Button semantics, the existing programmatic NavigationStack, retained List UI,
action fences, swipe actions and menus. Do not add gesture recognizers or scroll
restoration. Rebuild the isolated host without temporary diagnostics and run the
same two failing tests, followed by existing Journal/Favorites return checks.
The old center-tap intermittent failure remains unproven as the same defect.

The first final-source suite passes both trailing-space cases and Favorites
retention, but the middle-row center tap fails again before Append appears.
This disproves closure of the original intermittent issue from the hit-region
change. Retain that failure and collect a second action diagnostic on the new
source, writing its single record only after admission/emission evaluation.
Do not weaken the assertion or count this suite as a complete pass.

## Center-tap admission evidence

Three repetitions on the final label layout with post-evaluation action logging
produce one failed first tap and two successful repeated-return tests. The failed
callback names fixture row 0055, with enabled/member/presented all true but public
canInteract false and emitted false. This establishes a separate event-admission
failure at the native context boundary, not missing touch activation. Further
scratch-only diagnostics observe the current bound and timer contexts after a
denial; they do not replay the action or weaken any fence.

The follow-up diagnostic reproduces denial in repetition 3: the Button calls
binding 42 with presented=false, enabled/member=true and admitted/emitted=false.
At the next timer observation 57.894 ms later, binding 43 is presented and both
its bound closure and timer context admit interaction. Repetitions 1 and 2 pass;
iteration 1 includes an automatically handled notification interruption.

The next investigation is safe delivery of an explicit row action across a native
presentation update, retaining disposal, graph/resource ownership, membership,
modal and background fences. Do not solve this with unrestricted retries or
reintroduce scroll state. The decision remains proposed because this central
admission defect is now localized but not repaired. The independently reproduced
trailing-space hit-region fix is implemented and verified.

## Bounded open intent across a presentation commit

Batch 55 reproduces the defect before this implementation at the native Resource
boundary. The same physical repeated-detail test is the regression; the public
Application reducer is not the missing owner because no event reaches it. Do not
move ownership or duplicate that regression in reducer/transport tests.

Retain at most one explicit open intent when the current native context rejects
admission. Use the existing visibility timer and latest bound context to attempt
that intent only during a 250 ms monotonic window. Every attempt preserves current
membership, action-enabled, context admission and emit checks. Clear on success,
invalid membership/permissions, any superseding row action, native disposal, List
disappearance, or inactive scene. The enclosing root's graph-generation key owns
resource disposal on graph changes. Expiration prevents replay after modal or
long presentation interruptions. This is bounded delivery of one user command,
not repeated UI taps or an admission bypass; destructive/status actions are not
queued. Apply the same open behavior to Journal and Favorites.

Before implementation, the existing native regression has failed repeatedly with
recorded denied admission. Verification reuses it unchanged, plus Favorites,
trailing-space, Capture dismissal/background/save-to-top cases. Inspect cancellation
at each lifecycle boundary and preserve all failed runs. Do not claim deterministic
coverage of a sub-250 ms modal transition from ordinary slow XCTest taps.

Make modal cancellation explicit rather than relying only on the grace period:
application row actions are disabled whenever a modal is open, and Favorites
receives that same availability property. Binding either list's disabled snapshot
immediately discards its pending open. This preserves the native List while
Capture/Settings/status or other sheets are shown. The flag is produced by the
existing Application modal owner; there is no new route/scroll state or spec API.

## Capture regression investigation

The final navigation suite passes all five cases, including root 500. Capture
closing and background/foreground preservation pass, but the save-to-top assertion
fails with rows around 31 still visible. Quiescent readback confirms exactly the
new expected insert and healthy SQLite, so saving itself succeeded. Preserve the
failed run and inspect the native explicit scroll command before changing code.
This command remains necessary independently of the user-deferred/removed Back
scroll restoration. The failing observation is at the native scrolling boundary;
existing timeline reducer coverage verifies the explicit generation increment.

The diagnostic Capture repetition passes but records both explicit scrollTo calls
while presented=false and admitted=false, targeting the actual first block (not
a pinned header). This is unreliable presentation timing, not a reason to change
the target. Keep the earlier failed native test. Deliver the already existing
Capture scrollTargetID from the timer inside ScrollViewReader, only when the
current context is presented and admits interaction. Property changes install
the request; observed target visibility consumes it as before. Never create a
request on appearance or detail Back, and do not store viewport positions.

The admitted-timer scroll attempt still fails once in three unchanged Capture
repetitions. The failed hierarchy contains rows 33 onward and no first row;
this is an actual scrolling failure, not an accessibility query mismatch.
Preserve the run and add scratch-only request/install/visibility/issue records
to identify whether native callbacks consume or replace the explicit request.
Do not change the target or weaken the existing assertion without evidence.

## Confirmed Capture command loss during feed replacement

The three timing-instrumented repetitions fail, pass, fail. Both failures show
post-save row replacement with scrollGeneration still zero and no native request.
The pass shows generation 0 -> 1 -> 0, followed by successful scrolling.
Application's Sync_refresh Feed_loaded branch constructs Timeline.empty, resetting
the command counter. When Capture completion and refresh coalesce before rendering,
the native list never observes the command. The native visibility-consumption
hypothesis is disproven for these failures.

The existing public Root_navigation reducer exposes completion events but cannot
initialize calendar/feed-refresh state or observe its timeline; its create function
starts without a calendar and consequently rejects Feed_refresh_started. Timeline's
public reducer correctly preserves the counter through apply_feed, but Application
replaces that owner with empty. Do not bypass either .mli, copy Application logic,
or move ownership for test classification. Reuse the existing failing physical
Capture regression without adding duplicate layer coverage.

Add a timeline reset operation that clears data/pagination while retaining its
explicit command sequence within the same graph, and use it for Sync_refresh only.
Graph replacement still creates a new zero-based timeline and native resource.
Remove the speculative native admitted-timer scroll change: the actual defect is
the lost command before it reaches SwiftUI. Retain the original explicit command
delivery and verify unchanged Capture repetitions plus navigation retention.

## Batch 56 acceptance outcome

Final-source Journal/Favorites navigation and installed production Capture keyboard,
rotation and Close pass. One of three final isolated Capture lifecycle runs saves
and returns to top; two stop before editing because Capture does not reopen after
foregrounding. Preserve those failures separately from the repaired scroll command
loss. No claim is made that the toolbar failure has the same native owner as row
open. This decision stays proposed until that lifecycle acceptance is resolved.
See the batch-56 report and manifest for all intermediate failures and final hashes.

## Foreground Capture diagnostic

Batch 57 uses a disposable copy of the installed Swift framework in the isolated
host only. Observe standard Button activation outcome and native ancestor
mount/admission comparisons after evaluating the original action, without altering
its guards or reissuing taps. Log numeric identities and booleans only. The
production SDK and project remain unchanged. Restore the scratch package reference
and rebuild the host after the bounded existing Capture regression repetitions.

The first SDK diagnostic reproduces one failure among three runs. Capture's
standard Button activation is invoked on the correct mounted node, with matching
ancestor properties/bindings/children, but session.isActive=false and activation
is rejected. The other two complete successfully. This rules out a missing touch
callback for that failure. A second bounded diagnostic observes UIKit application
and scene activation states alongside runtime activation transitions, distinguishing
a premature automated tap from delayed/stale runtime lifecycle state.

The UIKit diagnostic reproduces two distinct failures: one callback sees UIKit
application/scene active while the runtime remains inactive for another 14 ms;
one callback occurs while UIKit itself is still inactive. The SDK repair observes
its window's scene notifications synchronously. The existing physical lifecycle
test also gains an explicit active-scene precondition after app.activate; the
fixture publishes its actual SwiftUI scene phase as the status accessibility value.
This is a state wait, not a sleep or repeated tap. Original failures remain intact;
the native UIKit owner test separately covers the delayed lifecycle defect.

## Final bounded acceptance

Batch 57 repairs the confirmed iOS lifecycle delivery defect in BonsaiSwiftUI's
existing window attachment. The corrected hosted UIKit owner regression changes
from red to green; existing input typography/focus/selection and eight macOS
session/environment tests pass. With an explicit active-scene test precondition,
three consecutive physical Capture/lifecycle/save-to-top repetitions pass. Final
Journal/Favorites detail return and installed production keyboard/rotation/Close
also pass. Isolated database readback confirms exact unique inserts and unchanged
prior payloads. Temporary diagnostic package references are removed.

The broad macOS SDK suite's incomplete exit is retained rather than reported as a
pass; relevant eight-test verification completes independently. This bounded
decision is implemented. The broader UI standardization proposal remains open.
See batch57-scene-activation.md and its manifest for evidence and limitations.

## Consequences

Explicit row opens survive short native presentation updates, Capture retains its command sequence across same-graph refreshes, and iPhone input admission follows its actual window scene. Detail Back retains native UI without saved positions.
