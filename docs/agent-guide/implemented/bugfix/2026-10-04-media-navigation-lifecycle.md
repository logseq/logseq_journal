# Media Navigation Lifecycle

## Problem

Application hides all media roots on each route change even when NavigationStack retains the covered page. Hide correctly releases the lease and drops its path, so native Back exposes a waiting slot without renewed appearance demand. A native visible range can arrive before path-changed and be discarded while Detail is active.

## Decision

Keep visibility separately for each retained presentation scope: the selected root destination and each live Detail request generation. Combine owners for each root and asset; release after its final owner leaves. Retire scopes on destination/path changes, reset on graph replacement, and release on app disposal. Preserve bounded groups, descriptor/ticket fencing and stale-acquire release. Native ranges may update the retained root owner while covered without rebuilding its model.

Application owns the erroneous route effect; the public route reducer has no media effects and the media reducer correctly releases on Hide. Injected Hide does not reproduce this defect. Regressions use the existing mounted Application/Worker public boundary, actual appearance/native navigation events, and Worker notices/completions. No duplicate reducer or transport regressions.

## Alternatives considered

### Restore attachments on Back

Still replaces File with Waiting during push and requires another acquire.

### Retain every root indefinitely

Leaks offscreen demand/leases and loses route ownership.

### Subscribe the whole root to the model

Reverses verified retained NavigationStack and targeted subscriptions without correcting file lifetime.

## Consequences

Covered entries retain bounded valid leases. Presentations of the same block share a controller; separate roots keep independent consumers. No Swift UI infrastructure, Dune or spec/ interface changes.

## Acceptance criteria

- Public Application RED then GREEN: Ready/in-flight Back, pre-path-change ranges, repeated push/pop, same-block entries, shared assets and last-owner release.
- True offscreen, graph reset and disposal release resources; stale completions/notices cannot reinstall paths.
- Build a consistent isolated dependency closure without altering global opam or owner checkout.
- Actual Application to C to Swift Simulator PNG/PDF Back retains ready media and list identity; honestly record frame cadence and unmeasured swipes.
- Local commit only: no push, PR, merge or physical-device installation.

## Risks

- The 64-root bound may refuse demand if all slots remain owned; preserve and verify it.
- Visible ranges arrive independently of path changes; root ownership cannot depend on active Detail state.
- Existing full-suite teardown failures remain explicit and outside scope.

## Questions

- Answered: the user authorized the diagnosed media lifecycle fix, tests, isolated Simulator verification and local commit. Other simplifications/publication remain excluded. The parent will create the independent review session after the frozen commit.

## Implementation evidence

The final mounted Application regressions include ten navigation/resource lifecycle cases plus the three existing targeted subscription cases. The identical new tests were run against unmodified main: Ready push/Back, pending Acquire Back, same-block entry ownership, offscreen path clearing, independent shared-asset consumers and leaf-before-root appearance fail before the fix. Old graph/completion fencing and Worker disposal controls already pass. All thirteen targeted cases pass with the fix, and the complete 39-case Application suite passed under dune.

A separate prefix holds frozen third-party libraries and freshly compiled Signal 868c145, LUI 67ea3e8 and Journal application/Worker objects; full native linking succeeds without ABI stitching. Actual Application-to-C-to-Swift Simulator baseline and fixed runs use valid PNG/PDF fixtures with natural Ready notices. Two fixed native Back cycles preserve original ready media nodes, list/collection identity, offset, content height and following-row anchors, with zero waiting slots and zero root/row rebuilds. Programmatic UIKit Back was exercised; interactive swipe completion/cancellation was not measured.

Full dune runtest completes after granting local loopback fixture and ephemeral native Security access with task-local compiler caches. Formatting and diff checks pass. An earlier complete Application run retained its existing initial-feed/chrome startup timeout; the isolated case passes and Worker teardown is unchanged. The historical bottom-lui-capsules decision still fails spec-dev-tool check --all for unchanged missing sections; this decision passes. Logs, manifests, screenshots and reports stay outside Git in the delegated task workspace. No reports, generated artifacts, dependency upgrades or unrelated UI fixes are committed.
