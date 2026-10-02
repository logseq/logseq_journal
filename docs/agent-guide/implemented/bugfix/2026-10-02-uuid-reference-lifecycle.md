# Fence UUID reference reads and release terminal Worker requests

## Problem

PR #38 introduced three reference-cache lifetime defects: a late older feed can replace a newer target title, a failed shared Changed_block read retains stale content, and outer Worker failure/cancellation is not routed back to the graph runtime and can exhaust its four hydration slots.

## Proposal

Keep the graph runtime as the owner of source freshness and bounded hydration. Fence source publication with monotonic request epochs and invalidation fences rather than ordering opaque revision strings. Give shared changed-block failures the same invalidation behavior as dedicated reference reads. Retain accepted Worker IDs for normal graph requests in the existing application adapter and convert every terminal outcome into a runtime failure completion, releasing slots and draining the existing queue. Keep OCaml/LUI and current main-tracked dependencies.

## Decision

Adopt monotonic local source epochs in the graph runtime, shared-read failure invalidation, and accepted Worker request ownership in the application adapter. The user authorized this local repair and a new draft PR.

## Alternatives considered

### Sort revision strings or reject only stale UI feeds

Revision tokens are opaque and other read types share the source cache. Fencing only the UI feed does not prevent runtime cache rollback.

### Add a separate retry scheduler or move ownership for testing

The existing runtime queue already owns the four-read budget. Keep its owner and test public operations; do not add a second scheduler or move ownership to make tests pure.

## Consequences

Opaque revisions remain unchanged. Freshness follows locally issued request ordering and change invalidation fences across all source fragments; equal-title results still advance their fence. Outer failures use the existing protocol failure owner and four-slot queue, without a second scheduler or per-row scans. Tests expose the existing Worker client only through the application testing API to drive real cooperative cancellation, and explicitly await fixture session detachment.

## Acceptance criteria

- Public runtime regressions reproduce stale overlapping feeds and failed shared Changed_block reads before the fix, and pass afterward.
- Worker outer Failed and Cancelled terminal events release four occupied slots, resume queued reads, fence late completions, and allow later target invalidation.
- Test the application/service boundary when the pure root reducer cannot represent accepted Worker ID registration or missing cleanup effects. Inject real Service.handle errors for outer Failed; label controlled cancellation simulation accurately.
- Applicable model, runtime, application, existing integration checks and native compilation pass; existing main failures and untested live-peer/device scope are recorded.
- Push only this independent branch and open one draft PR linked to the three review comments; no merge/deployment.

## Risks

- Request epochs indicate local read ordering, not global comparability of opaque revisions. Change invalidation must fence previously issued reads before they can publish.
- Fault injection covers deterministic public runtime and controlled Worker service behavior; it is not live database/cloud or simulator acceptance.

## Questions

None. The user explicitly authorized all three fixes, regression checks, push and a new draft PR.

## Verification

The formal pre-fix regressions fail (two runtime and two application cases), then pass after repair. Final behavior checks include 50 runtime and 12 application cases, actual Worker Failed/Cancelled delivery, four-slot recovery, queue drain, reread, late completion fencing and equal-title source epochs. Model, LUI, fifteen existing integration cases, routes and full/native compilation pass. Final full runtest retains only the clean-main source assertion requiring V.progress; 150 sync/transport cases pass with local loopback allowed. The existing unrelated decision-document failure remains. See docs/test-reports/2026-10-02-uuid-reference-lifecycle/README.md for evidence and the controlled-service/native-device limits.
