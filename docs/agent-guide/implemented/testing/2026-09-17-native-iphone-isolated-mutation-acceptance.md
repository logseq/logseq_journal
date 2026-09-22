# Native iPhone Isolated Mutation Acceptance

## Problem

The current signed production iPhone passes keyboard, draft and navigation checks,
but save, status mutation and deletion have only been verified with disposable
native macOS fixtures. Using the real account for destructive acceptance would
mix test writes with user data. The existing warm-start host is macOS-only.

## Decision

Extend the existing warm-start acceptance host and builder to iPhoneOS. Reuse the
current production OCaml Release object, Swift views, platform bridge and storage
with generated disposable encrypted graph fixtures. Keep authentication blocked
and both test secret stores memory-only in a distinct application container.

Support explicit fixture/support paths relative to the iPhone Documents directory,
so devicectl can transfer generated data without embedding host filesystem paths.
Retain the existing macOS command-line fixture workflow. Use the actual iPhone
scene and a compact test status/control area; distinguish this host layout from
the unmodified production app's visual acceptance.

Run native Capture/Append save, status selection, child-specific deletion and
restart persistence through XCTest. Copy the isolated graph databases back only
for read-only verification of queued operations. Add no duplicate pure reducer
regressions: this is device acceptance of already-covered production behavior.
Any newly reproduced defect must receive its own production-owner analysis.

## Alternatives considered

### Mutate the real account's graph

Rejected because independent fixture data provides exact expected IDs and avoids
adding acceptance records to the user's synced notes.

### Reimplement the screens in a SwiftUI preview

Rejected because it would omit the actual OCaml mutation owner, storage and bridge.

## Acceptance criteria

- The current production object and Swift views build as a signed iPhone host.
- Only generated data in the host's distinct container is read or mutated;
  in-memory keys and blocked remote authentication are required at startup.
- Actual iPhone save/status/delete interactions reach the intended block IDs;
  persisted local operations and restart behavior agree with the UI.
- Existing macOS host construction still compiles after platform conditionals.
- Evidence identifies the fixture size, object/source hashes, test results,
  screenshots and limitations. No false claims of remote sync or full performance.
- No Dune, protected spec or bonsai_flutter OCaml sources change. Undo/Redo and
  separator changes remain deferred by the user.

## Risks

- File transfer must retain the fixture directory structure while rebasing only
  the startup support root; production storage must derive its normal graph paths.
- Test status controls occupy additional vertical space and cannot establish
  production safe-area or toolbar layout acceptance.
- Release optimization with test-only crypto storage does not prove real-account
  network performance or production keychain behavior.

## Questions

- None. This completes the remaining device acceptance within the authorized scope.

## Current validation and user steering

The isolated iPhone Release host and UI test target compile. The host and fresh
two-graph fixture were installed successfully. XCTest waited for a locked phone
and was canceled before any test executed when the user took the iPhone away and
requested macOS testing first. No physical mutation acceptance is claimed. Keep
this decision proposed until the remaining device gates are verified.

The shared host still builds on macOS. Native macOS acceptance verified distinct
Append drafts and exactly one saved insert in each graph, despite matching parent
UUIDs. Partial child pagination after Append exposed a separate Journal_detail
cursor defect, tracked by refresh-child-continuations-after-append.


Batch 35 resumes physical execution on the paired iPhone 13. The production app
and isolated fixture install and launch. Capture/Todo/Done, partial-page Append,
child-specific swipe deletion/timed cancellation and deletion persistence pass
through staged XCTest runs and exact outbox checks. A sparse-tree Journal paging
defect discovered during acceptance is repaired in its own implemented decision.
The initial failures, later test-target corrections and repaired run are retained.
The device criteria above now have execution and exact persistence evidence.
Broader recovery, draft scoping and the full UI matrix remain tracked by the
main standardization proposal. No new Undo/Redo or separator implementation is
included.

## Consequences

The isolated host now provides both macOS and signed iPhone execution using the
current production object and views. Batch 35 records actual native Capture,
Append, status and child deletion/cancellation/restart outcomes. Final isolated
outboxes contain exactly the intended five operations in graph 1 and zero in
graph 2. Preserve failures and successful continuations separately; this is not
a claim that one complete fresh-fixture suite passed in a single invocation.
The public coordinator owns the newly found pagination defect and its five
regressions; the physical checks remain acceptance evidence. The complete
29-case UI scope and remaining human/performance gates are unchanged.
