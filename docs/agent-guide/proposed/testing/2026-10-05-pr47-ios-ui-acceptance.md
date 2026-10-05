# PR47 isolated iOS UI acceptance

## Problem

PR47 currently has green exact-head CI and deterministic regressions, but actual native left/right gestures and Save/Photos permission/write were not accepted. The user requested real Simulator acceptance and merge only after all relevant tests pass.

## Proposal

Use only device 7A45E48D-2909-4262-BFDC-93F16118B02D and generated synthetic data. CUA is unavailable in this session; build a disposable normal XCTest UI runner with xcodeproj, operating actual accessibility elements and gestures. Reuse the already compiled matching-head image fixture first. It cannot prove full Application Copy/status/delete/undo; those require a separate production Application fixture and real UI events. Verify actual Photos creation via normal Photos UI and generated image evidence; never grant album read permission to Journal. Store artifacts/screenshots Gitignored. No personal graph or phone. Fix any confirmed feature defect minimally using the narrow production state owner before updating the same PR. No Dune/spec modifications.

## Alternatives considered

### Internal event injection or controller assertions

Rejected for this acceptance: useful existing regressions cannot substitute for user-visible native interactions.

### Existing personal signed-in graph

Rejected: the user scoped disposable synthetic data and independent Simulator.

## Acceptance criteria

- Current PR/local SHA and fixture fingerprints match; all native input is normal XCTest/CUA.
- Actual block swipes have no action entry, and long-press Status/Delete/Undo and subtree Copy remain usable through real UI.
- Actual clicked image, paging, grouping, PDF exclusion, zoom/share/close/reopen and single/group current-image Save work.
- Add-only permission UI and actual Photos asset with original dimensions/current image are verified; duplicate/failure/close paths either pass or are explicitly blocked.
- Merge only after every required actual acceptance and final-head CI pass. A tool/approval limit prevents merge.

## Risks

- Permission authorization is relayed in the current delegation; automatic review may require a direct local user grant. If rejected, retry only the same operation once, then stop without alternative execution.
- Synthetic image fixture does not include the full Application UI; it cannot be used to claim its Copy/status/delete/undo pass.
- The real UI may reveal native containment/gesture problems missed by compiler/controller assertions.

## Questions

None for scope: the user authorized normal UI acceptance on this device, add-only Photos permission/synthetic saving, and conditional merge after passing. No merge is attempted until the conditions are met.
