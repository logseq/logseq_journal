# Keep Graph Selection Reachable After Startup Failure

## Problem

The actual two-graph native host with graph 1's wrapped key removed presents an
Unable to open graph screen with only Retry and Diagnostics. Graph 2 has a valid
local key and database, but the user cannot reach it. The sync manager already
supports Return_to_graph_picker; the error presentation omits that action.

## Decision

Keep the existing Retry action and add Choose another graph to the native startup
failure screen when a graph is selected and no local-deletion state is present.
Dispatch the existing switch-graph event. Do not retry, unlock, delete or write
anything as a consequence of choosing another graph. Keep startup failures with
no selected graph and deletion recovery outside this additional action.

The ownership check uses Journal_startup.derive and the Application public pure
interfaces first. Startup correctly reports Failed and its stage-specific recovery;
Root_navigation has no manager failure or rendered-actions interface. The omitted
button belongs to Application.manager_page. Cover only the existing deterministic
Application native-event harness with real public service snapshots and rendered
button dispatch. No already incorrect service result is injected: a missing local
key is a valid startup failure. Do not add duplicate core, transport or persistence
regressions. Confirm the repair in the existing native missing-key two-graph host.

## Alternatives considered

### Change startup recovery to choose a graph instead of retry

Rejected: online recovery remains useful. The UI needs both explicit choices.

### Always add the action to every failure

Rejected: an in-progress/failed local deletion has separate ownership, and a
failure without a selected graph has no current graph to leave.

## Acceptance criteria

- Public pure startup derivation correctly identifies the failure before repair;
  the native Application presentation regression fails on the missing button.
- Selected-graph local restore, bootstrap and graph-open failures expose Retry
  and Choose another graph. Selection dispatches only Return_to_graph_picker.
- No-selection and local-deletion failure cases do not acquire that action.
- Native missing-key graph 1 can return to the picker and open valid graph 2.
- Current regression checks and macOS/iPhoneOS builds pass, without Dune,
  protected spec or SDK changes. Undo/Redo stays deferred.

## Consequences

Application.manager_page now preserves Retry and adds a vertically stacked Choose
another graph action under the stated admission conditions. The existing manager
command remains the only dispatched operation. No startup state ownership moves.

A direct public Journal_startup.derive probe reports the correct Failed state
and Begin_online_recovery before implementation. The native Application harness
then fails on the absent action. Five final cases pass: local restore, bootstrap,
graph-open failure, no selected graph and local-deletion failure. A graph-state
case initially published its completion before the manager generation; the
fixture ordering was corrected to establish the generation first. That setup
issue is separate from the original missing-button reproduction.

The actual missing-key two-graph host presents the new button, returns to the
picker, and opens valid graph 2. Both graph outboxes remain empty and cooperative
shutdown passes. The host records explicit recovery admission before accepting
a later timeline, preventing its original missing-key startup expectation from
being confused with a successful user-selected alternate graph.

All registered macOS regressions, current macOS native/host builds and complete
unsigned iPhoneOS Release build pass. Evidence and hashes are in batch 29 of the
[implementation ledger](../../../test-reports/2026-09-16-native-swiftui-standardization/implementation.md).
No protected spec, Dune or SDK sources changed. Remote password unlock and
physical-device acceptance remain open.

Batch 39 adds physical iPhone evidence at normal and maximum accessibility text
size: Diagnostics, alternate graph selection, encrypted local opening and saved
selection after restart all pass, with both isolated outboxes empty. A separate
pending-Retry presentation omission is repaired by the subsequent startup
selection decision. Real remote authentication and wrong-password checks remain
open.

## Risks

- The action must not imply that encryption has been repaired or that online
  authentication is available. It only leaves the failed graph.
- Recovery now has bounded macOS and iPhone evidence; broader accessibility and
  real remote recovery gates remain open.

## Questions

- None. Reachable graph recovery is part of the existing UI standardization.
