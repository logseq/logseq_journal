# Reproduce Submitted Delete Recovery In Pure Reducer

## Problem

The macOS sync investigation used temporary probes that inspected implementation state. The user asks whether the two defects can be reproduced as pure_reducer testcases. M02 belongs to the sync Core policy, while M01's retained-window deletion belongs to the worker effect runner and cannot be reproduced by the current pure reducer alone.

## Proposal

Add public-API-only Core event-sequence tests to the existing sync test module. Use a submitted delete descriptor, a live-owner control, disconnect/reconnect, and a fresh Core attached to the same durable submitted descriptor. Assert correct recovery behavior so the unfixed M02 cases fail at the observed owner mismatch. Register them as a clearly named reproduction group. Do not implement production fixes or extract M01 into the reducer. Document the boundary and exact reproduction commands.

## Decision

Add three public Core cases in the existing test module: a passing live-owner control and failing recovery assertions for reconnect and fresh-Core restoration. Keep the known failures visible in a named reproduction group. Do not claim pure-reducer coverage of M01's effect-runner-owned window list.

## Alternatives considered

### Assert the current failure as success

This would encode the bug as expected behavior. Instead retain the intended recovery assertions and explicitly report the known failing reproduction cases.

### Reuse implementation-loading probes as unit tests

This would bypass the public interface and weaken the tests' boundary. Drive only public Core events, state, and emitted instructions.

## Acceptance criteria

- A live-owner deferred-delete control passes without I/O.
- Disconnect/reconnect and fresh-Core restore scenarios reproduce the M02 failure through public APIs.
- The failure comes from the recovery assertion, not invalid fixtures or compilation errors.
- No production, spec, dune, or bonsai_flutter source is changed.
- Report that M01 requires effect-runner coverage under the current architecture.

## Risks

- The default sync suite will contain deliberately failing regression cases until M02 is fixed. The report and testcase group must clearly identify this as the requested reproduction outcome.

## Consequences

The user now has a deterministic pure reproduction of M02, with a control distinguishing owner loss from an invalid deferred event. The two regression cases intentionally make the suite red pending a production fix. Existing source interfaces and test registration files require no dune or spec changes.

## Questions

None. The user requested executable pure_reducer reproduction; implementing a fix is outside the current scope.

## Validation outcome

The targeted group ran three tests in approximately 1 ms: the live-owner control passed, and both recovery cases failed with `authoritative defer owner mismatch` where the assertion expected no error. Full `dune runtest` reported 119 passing sync cases and those two failures. Build and formatting passed. The reproduction commands, scope boundary, and known red-suite status are documented in `docs/test-reports/2026-09-06-pure-reducer-sync-reproduction.md`. No production fix was implemented.
