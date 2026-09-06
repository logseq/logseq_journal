# Restrict Pure Reducer Reproducible Bugs to Pure Testcases

## Problem

A bug that can be reproduced through pure_reducer state transitions does not need additional regression coverage at the effect runner, integration, or UI layer. Adding the same reproduction at multiple layers increases fixture complexity, execution cost, and maintenance without improving the precision of the regression assertion.

## Proposal

For any bug that can be reproduced with a pure_reducer testcase, add only pure_reducer testcases for that bug.

This is an exclusive test-placement rule, not a preference to add a pure testcase first and then supplement it with higher-layer tests. Do not add effect_runner, transport, persistence, integration, E2E, or UI testcases for the same defect when the pure reducer can reproduce it.

Determine applicability before adding tests:

1. Identify the state owner and the observable incorrect behavior.
2. Attempt to express the triggering sequence through the reducer's public initial state, events, completion inputs, resulting state, and emitted instructions.
3. If that sequence exposes the defect, keep all newly added regression cases for it in pure_reducer. Include a control case only when it distinguishes the defect from an invalid fixture or a different failure.
4. If the defect cannot be reproduced at that boundary, explain which behavior is owned outside the reducer and add coverage only at the narrowest layer that executes that behavior.

A pure testcase must execute the faulty reducer behavior. Injecting an already incorrect result from another layer and checking its downstream presentation does not count as reproducing the external defect. Simulated effect completions are appropriate when the defect concerns how the reducer handles a valid completion.

Use public interfaces and deterministic event sequences. Do not access private implementation state, load implementation source around its interface, perform I/O, or relocate production state merely to classify a test as pure. Regression assertions must describe the intended behavior: fail on the bug and pass after its correction.

The rule governs newly added bug testcases. It does not authorize deleting existing tests or refactoring production architecture. Running an existing test or manually validating a fix is distinct from adding another regression testcase.

### Application to the sync investigation

- M02, lost submission ownership after reconnect or fresh-Core restore: reproducible through Core events and a valid deferred-authoritative completion. Add only pure_reducer testcases, including any necessary live-owner control.
- M01, an acknowledged change cursor becoming unusable: the retained-window list and destructive acknowledgement currently belong to the worker effect_runner. A pure testcase receiving an empty change result would not execute that defect. Coverage must exercise the actual owner of the window state.

## Decision

The exclusive placement rule is recorded in the repository `AGENTS.md`, including
public-interface requirements, the distinction between external failures and
reducer defects, and the prohibition on duplicate higher-layer regression cases.
No production code, existing tests, specs, or dune files were changed for this
policy decision. Existing diagnostic probes are historical investigation evidence,
not public-interface regression coverage.

Validation: `spec-dev-tool check --all` passed on 2026-09-06. Subsequent bug
decisions must record their own ownership evidence and failing/passing test runs.

## Alternatives considered

### Prefer pure tests but also add integration coverage for each bug

Rejected. This permits the duplicate coverage that the exclusive rule is intended to prevent.

### Require pure tests for every bug

Rejected. Transport, persistence, and effect-runner-owned behavior cannot always be reproduced by a reducer. Test placement must follow the behavior that causes the defect.

## Acceptance criteria

- Each bug's test placement identifies whether its cause is reproducible through the public pure_reducer boundary.
- When it is reproducible there, all newly added regression cases for that bug are pure_reducer testcases.
- No higher-layer testcase is added as supplemental coverage of the same pure-reproducible defect.
- Any non-pure testcase identifies the external behavior that a pure sequence cannot execute.
- Pure tests use deterministic public events and observable state or instructions, with intended-behavior assertions.
- This exploration changes no production code, existing tests, specs, or dune files.

## Risks

- Treating a mocked external failure as a pure reproduction can conceal the actual defective layer; review must verify that the testcase executes the faulty behavior.
- Distinct defects discovered during one investigation can have different state owners; classify them separately rather than applying one placement decision to the entire incident.

## Consequences

Future regression additions have an explicit repository-level placement rule.
Existing suites remain intact and may be run for validation. A pure helper that
does not own a reported failure cannot stand in for a reproduction of that failure.

## Questions

None. The user explicitly requested that bugs reproducible with pure_reducer receive only pure_reducer testcases. The user approved transition to proposed.
