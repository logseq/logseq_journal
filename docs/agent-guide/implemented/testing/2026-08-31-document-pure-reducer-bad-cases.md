# Document Pure Reducer Bad Cases

## Problem

The ten standalone pure-reducer bad-case tests identify their defect through
filenames, test names, and failing assertions, but they do not explain the
scenario at the source-file entry point. A reader must reconstruct the complete
setup trace before learning which ownership boundary the test is confirming.

## Proposal

Add one concise English file-level OCaml comment to each
`test_pure_reducer_bad_case_*.ml` file. Each comment states the asynchronous or
duplicate event being exercised, the expected fail-closed behavior, and the
currently observed reducer defect.

Do not change fixtures, event sequences, expected states, assertions, Dune
configuration, specifications, or reducer implementation.

## Decision

Adopt the proposal and use the same three-part `Scenario`, `Expected`, and
`Current bug` structure in every file-level comment.

## Alternatives considered

### Rely on filenames and Alcotest names

Those labels are concise but do not capture both the intended behavior and the
current defect at the point where a reviewer opens the file.

## Acceptance criteria

- Every one of the ten bad-case files starts with a scenario-specific English
  comment.
- Each comment distinguishes expected behavior from current buggy behavior.
- Only comments change in the OCaml files.
- All ten executables still compile and fail at the same semantic assertions.
- OCaml formatting, Dune build, and repository decision checks pass.

## Risks

- Comments can become stale when a reducer bug is fixed. The comments therefore
  describe both the invariant and the currently confirmed behavior explicitly.

## Consequences

- Reviewers can understand each defect confirmation before reading its fixture.
- A later reducer fix must update the corresponding current-behavior statement.

## Questions

None. The requested scope and language are explicit.

## Implementation

Added one file-level OCaml comment to each of the ten standalone bad-case files.
No executable test expression, assertion, dependency, specification, or reducer
source changed.

## Verification evidence

- All ten files contain a scenario-specific comment with expected and current
  behavior.
- `ocamlformat --check` passes for all ten files.
- `dune build @all` passes.
- `dune runtest logseq_sync/test --force` keeps the existing 53 tests green and
  reaches the same intended failing assertion in BC01 through BC10.
