# Media Early Return Owner Handoff

## Problem

Independent review of b3ab77d reproduces a remaining early native Back sequence. Timeline releases its root owner while Detail still holds the valid file. Timeline's returning root/leaf appearance precedes path-changed and is discarded by the active-route guard. Popping Detail then releases the final lease although Timeline is actually visible.

## Decision

Accept native root/asset appearance from every validated retained presentation scope, including a covered page returning before path-changed. Keep active-route filtering for user actions, graph/route scope validation, true offscreen range releases, controller owner union and all stale-response/lease protections. Range alone remains a release filter rather than creating demand for metadata-only assets. Preserve b3ab77d as before and freeze a new after commit locally.

Application owns the active-route effect guard; its pure route reducer cannot execute this guard, and a media reducer test would have to inject the already missing Show. Reuse the reviewer's narrow mounted Application probe with unchanged sequence and assertions. No duplicate lower-layer regressions or UI coordination infrastructure.

## Alternatives considered

### Reorder appearance after path-changed in the test

Skips the actual native event ordering and does not correct ownership.

### Demand every metadata asset on visible range

Creates demand without actual asset appearance and changes existing lazy resource behavior.

## Consequences

Only Application's validated root/asset appearance branches bypass the active-route guard. Retry/Next still use that guard. No Runtime, graph/path scope validation, lease reducer, Native NavigationStack, Dune or spec/ interfaces change. The existing fixture now reads the latest owner reply revision for settled, exactly as LUI 67ea3e8 Swift complete does; the reviewer's event order and both assertions remain, with additional no-demand-release/no-reacquire/original-leaf assertions.

## Acceptance criteria

- The reviewer's exact early return sequence is RED on b3ab77d and GREEN after the fix, preserving the ready file without release or reacquire.
- Existing offscreen, retired scope, graph and stale Acquire controls continue passing.
- Complete appropriate tests and actual native PNG/PDF before/after verification with the isolated fixed dependency closure.
- Local commit only; parent arranges a new independent review. No push or phone installation.

## Risks

- Native appearance is valid before active-route publication; route identities still have to be retained and graph-current.
- The independently reported preview and Detail-collapse resource lifetime issues remain outside this focused authorization and must stay visible to the parent.

## Questions

- Answered: the parent explicitly authorized completing the early-return flicker fix, preserving the independent probe and before/after evidence, then handing a new local HEAD back for independent review.

## Implementation evidence

The exact review branch was imported from the stable reviewer v1 source. Its original frozen-commit sequence fails with file release 1, demand release 1 and no files. After correcting only the fixture's settled revision, the identical final test was run against an independent b3ab77d production copy and the fix. Before full dune runtest fails only the new early-return Application case (39 of 40 Application cases pass); after force-running the full suite succeeds (all 40 Application cases pass). After the counterexample: file release 0, demand release 0, one original ready Timeline leaf retained, no reacquire. Media reducer/runtime, actual offscreen and stale completion controls remain passing. Canonical task-local fixture paths and the same frozen dependency prefix are used; initial setup failures are retained outside Git.

Actual Application-to-C-to-Swift PNG/PDF control preserves the early-event ordering. Before path retirement both assets become Waiting with two releases; after they remain Ready without release or reacquire. The control is explicitly synthesized native event ordering; real normal UIKit Back is recorded separately. Independent review will consume the new frozen HEAD, full diff and external manifests rather than implementation promises. Existing preview/collapse findings and interactive swipe limits remain explicit; no unrelated fix, push or phone installation is performed.
