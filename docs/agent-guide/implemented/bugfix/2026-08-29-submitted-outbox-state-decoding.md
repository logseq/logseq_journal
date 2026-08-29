# Submitted Outbox State Decoding

## Problem

The outbox encoder serializes both `Queued` and `Submitted` as objects whose
only field is `type`. The decoder's first exact-shape branch accepts every
single-field `type` object but recognizes only `queued`, so the encoder's own
`{"type":"submitted"}` output fails with `invalid queued outbox state`.

After a queued mutation is durably transitioned to `Submitted`, any path that
decodes the persisted outbox can therefore fail. In the macOS application this
surfaces during normal sync processing or after reopening an existing graph.

## Proposal

Decode both `queued` and `submitted` in the shared exact-shape branch for
single-field outbox states, and remove the unreachable later `submitted`
branch. Add a contract regression test that drives a real queued record through
the submission transition and decodes the produced durable outbox records.

The scope is limited to correcting the current outbox codec. No compatibility
path or migration is introduced because the failing value is already the
current encoder's canonical representation.

## Decision

Decode both `queued` and `submitted` from the canonical exact one-field state
shape. Keep rejecting extra or malformed fields, and remove the structurally
unreachable submitted-only branch.

## Alternatives considered

### Reorder the existing branches

Placing the existing submitted-only branch before the queued branch would make
`submitted` decode, but it would make `queued` fail for the same structural
reason. Dispatching both values from the one-field shape directly represents
the wire contract.

## Acceptance criteria

- A queued outbox record produced by a local mutation still round-trips.
- A record transitioned to `Submitted` by `plan_submission` decodes from the
  transition's durable `outbox_records` without error.
- Malformed state shapes continue to fail closed.
- The focused sync contract tests and the complete repository test suite pass.
- A rebuilt macOS application can reopen the affected graph and process another
  mutation without `invalid queued outbox state`.

## Risks

- A broader decoder could accidentally accept additional fields. Exact field
  validation remains unchanged, so only the canonical single-field submitted
  value becomes accepted.

## Consequences

- Current encoder output is closed under decoding for both one-field states.
- Restart and subsequent mutation paths can read durable submitted records.
- The codec remains strict and does not introduce a compatibility format or
  migration.
- Downstream handling of server `tx/reject` messages remains a separate issue.

## Questions

- None. The encoder output, decoder control flow, and reported runtime error
  identify the defect and desired behavior unambiguously.

## Implementation

`outbox_state_of_json` now decodes both canonical one-field states in its
single exact-shape branch. The unreachable later `Submitted` match was removed.

The sync contract test drives a real local record from `Queued` through
`plan_submission`, then decodes the resulting durable transition records. The
test failed before the implementation with `invalid queued outbox state` and
passes after the decoder change.

## Verification evidence

- `dune exec logseq_sync/test/test_sync.exe -- test 'pure core' 27` passed after
  first demonstrating the exact expected failure.
- `dune runtest`, `dune build @all`, `dune build @fmt`, `git diff --check`, and
  `spec-dev-tool check --all` passed.
- Flutter host tests passed with 21 tests and 5 intentional skips; Flutter
  analysis reported no issues.
- The debug macOS application built successfully with `bonsai-flutter`.
- In the running macOS application, SQLite inspection confirmed two durable
  records whose state was `submitted`. The application was exited and restarted
  with those records intact, restored the same `ocaml-sync-test` graph without
  `invalid queued outbox state`, and accepted another Capture mutation.

The live submission subsequently exposed `unsupported authoritative message:
tx/reject`. That error is downstream of successful submitted-state decoding and
is outside this codec bugfix.
