# Strengthen BC08 Replacement Challenge Coverage

## Problem

`test_pure_reducer_bad_case_08_reused_graph_token_challenge.ml` proves that a
replacement WebSocket token challenge must have a fresh ID and that a late
response to the rejected challenge must be ignored. It does not prove that the
replacement challenge remains usable or that it is consumed exactly once.

A reducer that rejects every token response after retry could therefore satisfy
the stale-response assertions without preserving forward progress.

## Proposal

Extend only BC08 with an independent positive branch from the state that owns
the replacement challenge:

- submit the replacement token request and require exactly one scoped
  `Start_websocket` instruction;
- replay the consumed replacement request against the resulting state and
  require an exact no-op; and
- retain the existing independent stale-request branch, fresh-ID assertion,
  public-state checks, graph-admission checks, immutability check, and
  deterministic replay check.

Run the positive branch before the intentional fresh-ID failure so the current
reducer executes the new assertions. Do not modify the reducer, specifications,
Dune files, or any other testcase. BC08 remains intentionally RED because the
current reducer reuses the graph-token challenge ID.

## Decision

Adopt the testcase-only strengthening. The positive and stale branches must
start from the same immutable replacement-challenge origin so neither branch
consumes or otherwise changes the other branch's input state.

## Alternatives considered

### Test the replacement request after the stale branch

This would work only after stale-request rejection is fixed. Against the current
bug, the stale response consumes the pending challenge and prevents the positive
path from exercising the replacement request. Independent branches make the
causal expectations explicit.

### Fix the reducer in the same change

This is outside the requested testcase-optimization scope. The bad-case
executable is intended to remain RED until a separate reducer bugfix is approved.

## Acceptance criteria

- BC08 derives the replacement request and WebSocket scope only from checked
  reducer effects.
- A valid response to the replacement request emits exactly one
  `Start_websocket` instruction with the replacement token and current graph
  scope.
- Replaying the consumed replacement request emits no instruction and preserves
  public state and graph admission.
- The stale rejected request remains an independent no-op expectation.
- The testcase compiles and still fails specifically because the replacement
  challenge ID is reused.
- OCaml formatting, repository build, whitespace, and agent-document validation
  checks pass.

## Risks

- The positive branch adds a small amount of assertion code to an already long
  standalone testcase, but keeping it local preserves the one-file bad-case
  boundary.
- Repository-wide `dune runtest` remains intentionally RED because all ten bad
  cases are registered as tests before their reducer fixes.

## Consequences

- BC08 will reject both unsafe stale acceptance and a liveness regression that
  makes the replacement challenge unusable.
- The test will constrain replacement challenges to one successful consumption.

## Questions

None. The user explicitly requested the identified BC08 testcase optimization.

## Implementation

BC08 now forks two transitions from the same immutable replacement-challenge
origin. The positive branch submits the replacement request, requires exactly
one `Start_websocket` instruction for the current graph and replacement token,
checks public state and graph admission, and verifies that a duplicate response
is inert. The existing stale branch remains independent and continues to verify
fresh challenge identity, stale-response rejection, origin immutability, and
deterministic replay.

The file-level scenario comment now records both replacement-response liveness
and stale-response safety. No reducer, specification, Dune file, or other
testcase changed.

## Verification evidence

- The BC08 executable compiles.
- The replacement-response state, graph-admission, and one-shot-consumption
  assertions execute and pass against the current reducer.
- BC08 then fails at the intended fresh opaque ID assertion because the current
  reducer reuses the challenge ID.
- OCaml formatting passes for the strengthened testcase.
- `dune build @all` passes and the existing 53-test `test_sync.exe` suite remains
  green.
- The scoped `dune runtest` alias remains intentionally RED at the ten registered
  reducer bad cases, including BC08 at the expected ID-reuse assertion.
- Repository whitespace and all agent-document validation checks pass.
