# Current iPhone Performance Coverage

## Problem

Historical iPhone performance traces predate native List retention and synchronous scene activation. One animation trace ends sampling before the final wall-clock-mapped interactions. Current Release first-content, scrolling and lifecycle evidence remains incomplete.

## Proposal

Refresh the existing isolated full-runtime Release host from current production Swift sources and the verified iPhone native object. Use a fresh disposable 500-root, 135-child graph. Record a no-AX Activity Monitor baseline and an App Launch trace, then separately record controlled scrolling, loaded idle and lifecycle interactions. Validate target sample coverage and timestamp mapping before deriving phase metrics. Preserve traces, source hashes, raw tool failures and evidence limits. Do not infer rendering latency from XCTest command duration.

## Alternatives considered

### Reuse historical traces

Rejected because they predate the current production behavior and have known coverage limitations.

### Profile the user's graph while changing its data

Rejected because a disposable fixture provides controlled counts and avoids unnecessary live writes.

## Acceptance criteria

- Refresh and verify the isolated Release binary against current production inputs.
- Collect direct current-device resource or launch metrics without AX interaction.
- Collect separate scrolling/lifecycle evidence with validated coverage before claiming phase performance.
- Record unsupported metrics and remaining gates without labeling the overall UI goal complete.
- Preserve production credentials, data, retained native List navigation and all user-deferred scope.

## Risks

- Instruments and XCTest add overhead; fixture key generation and blocked authentication differ from production startup.
- Tool coverage and clock alignment may require additional exports before phase attribution is justified.

## Questions

None. Performance acceptance and isolated device testing are already authorized.

## Measurement refinements

The combined animation recording finishes successfully after a lengthy local save; this is tool processing, not application time. A separate Activity Monitor plus Points of Interest trace completes all corrected interactions. Unlike Animation Hitches, it does not export time-info. Its phase mapping is independently corroborated by the XCTestCase begin/end signposts emitted by the same device runner: the begin follows the logged test start by 84 ms, and the end follows the final phase by 88 ms. Use that bounded wall-clock mapping without a guessed offset for resource windows, trimming three leading and two trailing seconds from idle intervals. Preserve device mach timestamps for cross-checking; do not claim a directly exported mach epoch for this template. Target resource samples extend beyond the final phase.

## User-directed pause — 2026-09-18

The user stopped further work and closed the main UI implementation. This
follow-up remains proposed and paused; resume only on a new user request.
The short control completed with test and trace exit code zero; its analysis
remains unperformed and is not claimed as performance acceptance.
