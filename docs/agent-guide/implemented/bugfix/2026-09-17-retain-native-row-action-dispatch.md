# Retain Native Row Action Dispatch

## Problem

On the signed iPhone build, the first cold-launch Journal context menu exposes
Change status but selecting it does not open Set status. The same interaction
succeeds afterward. Two unchanged physical acceptance runs reproduce the failure.
The application status transition already opens the sheet when write admission,
row existence and pending-mutation gates permit it. That pure boundary does not
execute SwiftUI retaining native menu closures while the list receives viewport
updates. Existing native-owner generation checks intentionally reject expired
callbacks; those checks must remain intact.

## Decision

Resolve Journal row menu/swipe actions through the list's existing resource,
which receives the current typed action closures when the native view renders.
The retained platform menu keeps the stable row identity and list resource;
at activation the resource checks current action permission and row existence
before calling the current typed emitter. Disposal clears dispatch. The keyed
graph root already disposes the resource when the graph generation changes.
Physical cold-launch acceptance verifies the repair. The debugger did not capture
the failing callback's exact generation; successful later admission was observed.

## Alternatives considered

### Relax SDK generation checks

Rejected: obsolete callbacks and inactive pages must continue to reject input.

### Recreate the whole list on each acknowledgment

Rejected: this would discard native scroll and row lifetimes for unrelated
viewport or binding updates.

### Delay menu activation

Rejected: a timing delay does not establish that the action belongs to the
current row, graph or mounted page.

## Acceptance criteria

- The unchanged cold-launch physical row-action acceptance opens Set status on
  the first context-menu action and exposes all current status options.
- Close preserves row content/status. Merely revealing trailing Delete does not
  invoke it. Local-copy confirmation is a separate application acceptance case;
  the action was temporarily absent from the current graph menu, then became
  available on a fresh launch and passed its separate Cancel acceptance.
- Current resource disposal, row membership and typed canInteract/emit admission
  guard dispatch; no SDK fence is relaxed and no graph mutation is used by tests.
- Keep the existing physical flow as the narrow native regression because the
  retained SwiftUI callback cannot be exercised through the app's pure events.
- If the candidate fails the same context-action check, revert it and retain the
  failed investigation evidence.

## Consequences

Retained native menu closures use the current typed dispatch for a still-present
row in the same live graph resource. Removed rows and disposed resources cannot
use this path. Current SDK admission still rejects inactive/unacknowledged input.
The physical cold-start action and complete read-only acceptance pass after the
repair; the Release build and existing viewport checks also pass. Local-copy
Cancel passed separately after refreshing the screen and disambiguating UIKit's
nested accessibility buttons. See batch 21 in the implementation ledger.

## Risks

- A menu can remain visible while viewport updates replace handler bindings.
  Only action-time current bindings may dispatch; removed rows and disposed
  graph resources must reject it.
- The physical result is required: successful later interactions do not prove
  cold-launch behavior works.

## Questions

- None. This repairs the approved native row-action behavior without a product
  decision or protected-interface change.
