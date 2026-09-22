# Scope Outline Actions to Their Row

## Problem

In the isolated native acceptance host, invoking the appended child's exposed
Delete action commits a delete for its parent root and all descendants. The
native action tree exposes identically named actions inherited through a
DisclosureGroup. The broad refresh then exhausts the worker request queue.
The wrong target is the first issue to isolate; queue fan-out is separate.

The production owner of action placement is JournalOutline.Branch in SwiftUI.
The public app/detail reducers accept an explicit block ID and cannot reproduce
native parent/descendant action inheritance without injecting the already wrong
ID. Use the existing production registration in a small native host that displays
emitted event targets, with no database or destructive operation.

## Decision

Reproduce child versus parent action selection using the real JournalOutline
registration and static valid hierarchy metadata. Place per-row native actions
on the individual row label/content instead of wrapping an entire expanded
subtree. Keep native DisclosureGroup, List and semantic destructive actions.
Verify parent, child and sibling targets and expansion after the repair.

## Alternatives considered

### Reject parent deletion while expanded

Rejected: it hides the incorrect native ownership and removes valid behavior.

### Rewrite the target in the application reducer

Rejected: the reducer cannot infer which native row the user acted on.

## Acceptance criteria

- The production native registration reproduces the wrong target before repair.
- Child, parent and sibling Delete actions emit exactly the selected block ID.
- Disclosure expansion remains functional and does not trigger deletion.
- No copied production implementation or duplicate reducer regression is added.
- Shared Swift changes compile for macOS and iOS. Physical iPhone verification
  stays open while the device is unavailable.
- No Dune or protected spec files change; Undo/Redo remains deferred.

## Consequences

The production modifier chain now belongs to the individual label instead of the
entire expanded subtree. Native Delete and context-menu actions target all four
fixture identities correctly; the unchanged probe reproduced parent targeting
before the repair. Actual child Delete/Undo restores the row without a committed
outbox mutation, and real disclosure still works. macOS and unsigned iPhoneOS
Release builds pass. See batch 24 in the native standardization implementation
ledger and `apple-tests/native-outline/README.md` for the repeatable native probe.

The separate bulk-change request fan-out failure remains open. Physical UIKit
swipe/VoiceOver acceptance is not implied by the macOS check.

## Risks

- Moving actions to a label must retain native swipe/context accessibility.
  Inspect actual native actions instead of assuming modifier semantics.
- macOS evidence does not prove UIKit's gesture behavior.

## Questions

- None. This repairs the authorized native row action and data-target behavior.
