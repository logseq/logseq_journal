# Integrate Pure Reducer Bad Cases With Dune

## Problem

The ten standalone `test_pure_reducer_bad_case_*.ml` executables currently live
under `logseq_sync/test`, but `logseq_sync/test/dune` declares an explicit module
list containing only the existing green `test_sync` executable. Dune therefore
does not compile or run the new reducer defect confirmations, and developers
must use a separate manual `ocamlfind` harness.

The bad cases intentionally remain RED until the corresponding reducer defects
are fixed. Keeping them outside Dune, however, makes the build graph incomplete
and obscures whether a future interface or dependency change prevents them from
compiling.

## Proposal

Add one `(tests ...)` stanza to `logseq_sync/test/dune` naming all ten standalone
bad-case executables. Give them the direct libraries required by their public
fixtures: `alcotest`, `datascript-ocaml-native`, `datascript_ocaml`,
`logseq_db_types`, `logseq_sync.pure_reducer`, and `uri`. The native Datascript
implementation is required because `datascript_ocaml` is a virtual library.

Retain the existing `test_sync` stanza unchanged. Do not combine the bad cases
into one runner, add wrapper modules, duplicate their test bodies, or modify the
reducer implementation. Each `.ml` file remains one independently addressable
Dune test executable.

The intentional result is:

- `dune build logseq_sync/test` compiles the green suite and all ten bad cases;
- `dune runtest logseq_sync/test` runs all eleven executables and fails because
  the ten reducer defects are still present; and
- an individual case can be run with
  `dune build logseq_sync/test/<name>.exe` followed by that executable, or with
  Dune's test alias targeting the generated test action.

This decision supersedes only the earlier bad-case decision's temporary external
verification harness and its choice to omit the files from Dune. The test
semantics, one-file-per-case layout, and no-reducer-change constraint remain in
force.

## Decision

Adopt the proposal. Register all ten files in one `(tests ...)` stanza so Dune
creates ten independently runnable executables and test actions.

## Alternatives considered

### Keep the external `ocamlfind` harness

It proves the files compile, but it duplicates Dune's dependency resolution and
does not make the tests discoverable through the repository build system.

### Add ten separate `(test ...)` stanzas

This is behaviorally equivalent but repeats the same library list ten times. A
single `(tests ...)` stanza still creates ten separate executables and actions.

### Merge the bad cases into `test_sync`

This would reduce executable count but violate the requested independent-file
layout and make the existing green suite inseparable from deliberate RED defect
confirmations.

## Acceptance criteria

- `logseq_sync/test/dune` names every one of the ten bad-case modules exactly
  once.
- Dune builds all ten executables without warnings or dependency errors.
- Dune runs every bad case and each fails at its documented semantic assertion,
  not during compilation, linking, or fixture setup.
- The existing `test_sync.exe` still passes when run directly.
- No reducer implementation, specification, or bad-case test body changes.
- `dune build @all`, new-file formatting checks, `git diff --check`, and
  `spec-dev-tool check --all` pass.

## Risks

- The scoped and repository-wide `runtest` aliases intentionally become RED
  until all ten defects are fixed or their expectations are explicitly revised.
- CI lanes that require `dune runtest` to be green will fail immediately. This is
  the requested visibility rather than an infrastructure failure.
- Adding a new bad-case file later requires adding its executable name to the
  explicit Dune stanza.

## Consequences

- Dune becomes the single source of truth for compiling and running these tests.
- Developers can run one defect confirmation by its executable name.
- The external manual compilation command is no longer required.

## Questions

None. The user explicitly requested that every existing bad case enter the Dune
build system and accepted the resulting RED test alias.

## Implementation

`logseq_sync/test/dune` now lists each `test_pure_reducer_bad_case_*.ml` module
and its direct libraries. The existing `test_sync` stanza, reducer source,
specifications, and bad-case test bodies remain unchanged.

## Verification evidence

- Dune built all ten bad-case executables successfully.
- `dune runtest logseq_sync/test --force` ran the existing 53-test green suite
  successfully, then ran all ten bad-case executables.
- Every bad case reached its documented `BC01` through `BC10` semantic assertion
  and failed there as intended.
- The remaining acceptance checks passed as recorded during implementation.
