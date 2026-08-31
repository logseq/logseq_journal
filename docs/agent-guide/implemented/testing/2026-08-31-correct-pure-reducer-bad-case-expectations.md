# Correct Pure Reducer Bad Case Expectations

## Problem

Three pure-reducer bad-case tests encode or verify their expected behavior
incorrectly.

BC08 requires the old and replacement graph-token challenge IDs to be equal even
though the stated invariant requires a fresh identity. A reducer fix would
therefore make the defect test fail before it could verify stale-response
rejection.

BC10 requires a mismatched outbox completion to be ignored but does not define
how the reserved submission can subsequently make progress. It checks only the
public state and immediate effects, so a reducer could silently corrupt or drop
the private reservation and still satisfy the negative assertion.

BC07 applies the stale old-account catalog completion before establishing the
origin used for immutability and replay checks. Its final empty-catalog probe
detects the current contamination, but the test does not directly establish
that the stale completion itself is deterministic and inert.

## Proposal

Correct only the three affected standalone tests.

- BC08 must require the replacement graph-token challenge ID to differ from the
  rejected challenge ID, then retain the stale-response no-WebSocket assertion.
- BC10 must define recovery as retaining the reservation after an invalid
  completion so a later exact completion can dispatch the originally reserved
  message. It must first assert that the mismatch is inert, then submit the
  matching completion and assert the exact ordered WebSocket send and state
  publication.
- BC07 must use the pre-stale-completion restoration state as the bad
  transition's origin, assert its exact public no-op behavior and deterministic
  replay, and retain the new-account local-load completion as a probe that the
  stale result did not contaminate private state.

Do not modify the reducer, specifications, Dune files, or any other bad case.
The corrected tests remain intentional RED tests against the current reducer.

## Decision

Adopt the three test corrections and the BC10 later-exact-completion recovery
semantics described above. Keep production reducer changes outside this
test-only decision.

## Alternatives considered

### Alternative

Treat a mismatched BC10 completion as a terminal failure or as an outbox
rejection. This is not selected because the event may be an unsolicited or
duplicated malformed callback followed by the actual owned completion. Keeping
the exact reservation while rejecting the malformed callback preserves both
fail-closed safety and a directly testable recovery path without trusting the
mismatched payload.

## Acceptance criteria

- BC08 fails on challenge identity reuse and would continue to verify that a
  stale response cannot start a WebSocket after challenge identity is fixed.
- BC10 proves that the mismatched completion emits nothing, preserves public
  state, and leaves the original reservation able to consume one later exact
  completion.
- BC07 replays the old-account completion from the new account's restoration
  state and proves through the later local-load completion that the new catalog
  remains empty.
- All three files compile and fail at their intended current reducer defects.
- OCaml formatting, build, repository whitespace, and agent-document validation
  checks pass.

## Risks

- BC10 intentionally chooses recovery by a later matching completion. A separate
  timeout policy would be required if the runner can permanently lose the owned
  completion, but that production policy is outside this test-only correction.

## Consequences

- A future graph-token fix makes BC08 progress past challenge creation instead
  of causing the test itself to regress.
- BC10 now constrains both mismatch safety and reservation recovery.
- BC07 directly identifies the stale completion as the bad transition while
  preserving the later catalog load as an observable contamination probe.
- The three files remain RED until their corresponding reducer defects are
  repaired.

## Questions

None. The requested corrections and the selected BC10 follow-up-completion
recovery define the test-only scope.

## Implementation

BC07 now establishes the new-account restoration state as the origin of the
stale old-account completion, verifies its public no-op behavior and replay,
and then uses the new account's empty local-cache completion to detect private
catalog contamination.

BC08 now requires the replacement graph-token challenge to have a fresh opaque
ID before exercising the stale response.

BC10 now retains its mismatch no-op assertions and adds a matching follow-up
completion that must consume the original reservation, emit exactly one
WebSocket send, and publish the Submitting state.

No reducer, specification, Dune file, or unrelated bad case changed.

## Verification evidence

- All three corrected executables compile.
- BC07 fails at the final empty-new-account-catalog probe after the stale
  completion's direct no-op and replay assertions pass.
- BC08 fails at the fresh replacement challenge ID assertion.
- BC10 fails because the mismatched completion changes the public state instead
  of remaining inert; the exact follow-up recovery assertions are ready for the
  reducer fix.
- `dune build @all` passes.
- The existing `test_sync.exe` reports all 53 tests passing.
- `ocamlformat --check`, `git diff --check`, and agent-document validation pass.
