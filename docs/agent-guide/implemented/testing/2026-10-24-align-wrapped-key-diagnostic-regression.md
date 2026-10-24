# Align Wrapped Key Diagnostic Regression

## Problem

PR #114 compiles in CI but the existing wrapped-key crypto harness still expects the old generic `crypto-failed` log result. The production bridge now reports the finite underlying `cryptoAuthenticationFailed` cause for the synthetic invalid AES tag. The regression must continue checking the actual C entrypoint, opt-in logging, stages, operation identity, duration and privacy rather than dropping the terminal-result assertion.

## Decision

Reproduce the existing failing harness, inspect its actual JSON response and terminal log, then align that harness with the precise finite reason. Assert the response is unsuccessful with the authentication reason and that its matching terminal record has the expected operation, request, stage and a nonnegative numeric duration. Retain log caps, secret-marker checks and missing wrapped-key classification. Change no production source, spec, Dune or dependencies if the real producer already satisfies those requirements.

## Alternatives considered

### Revert the producer to a generic error

Rejected because it would discard the safe underlying reason the user explicitly requested.

### Remove the assertion or rerun CI unchanged

Rejected because neither verifies terminal logging and neither addresses the deterministic mismatch.

## Acceptance criteria

- The unchanged existing harness fails for the same terminal-result assertion as CI.
- The corrected existing harness verifies the exact response and terminal record, opt-in silence, stage progression, missing-cache distinction, secret exclusion and output cap.
- The existing owner harness passes locally, then the updated PR head passes full CI and is checked for review findings.
- Production source and the previously verified 6506 App remain byte-identical; no additional graph writes or rebuild are required for a test-only correction.

## Risks

- An overly broad terminal-string check could accidentally pass when a different request emits the reason; match the exact operation/request record and numeric duration.

## Questions

- No unanswered product or permission questions. The user authorized this diagnostic change and the parent explicitly requested fixing this PR's CI without skipping failures; this correction is limited to the existing synthetic test.

## Consequences

- The original harness reproduced CI's terminal-result assertion failure locally. An external probe of its actual C entrypoint showed `result=cryptoAuthenticationFailed stage=open-private-key elapsed_ms=2697`; the failure was a stale generic-result expectation, not absent terminal telemetry.
- The existing harness now decodes the actual response, requires the exact authentication reason and exactly one terminal record for operation 109, and checks the actual stage and a nonnegative integer duration. Existing opt-in silence, stage progression, secret exclusion, log cap and wrapped-key recovery checks remain.
- The complete existing wrapped-key harness passes locally after this test-only correction. CI on the updated PR head remains required; no test is skipped or added to a new CI route.
- No production source, native/Swift input, protected spec, Dune file or dependency changed. The 6506 normal App/Web acceptance remains valid for the identical product code, with its documented runtime coverage limits.
