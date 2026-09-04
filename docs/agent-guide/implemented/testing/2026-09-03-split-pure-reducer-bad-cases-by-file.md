# Split Pure Reducer Bad Cases By File

## Problem

`logseq_sync/test/core_contract.ml` currently contains the canonical happy path,
the existing focused reducer cases, shared bad-case fixtures, and all ten
ownership bad cases. The combined file obscures the boundary of each bad case
and makes focused review harder.

The previous standalone files cannot be restored under their obsolete
`test_pure_reducer_bad_case_*` names because source-boundary checks intentionally
forbid those overlay-pre-cutover paths.

## Proposal

Move BC01 through BC10 into ten current-API modules named
`pure_reducer_bad_case_01.ml` through `pure_reducer_bad_case_10.ml`.

Move only their shared public-API fixtures and assertion vocabulary into
`pure_reducer_bad_case_support.ml`. Keep the seventeen-checkpoint canonical
happy path and the fifteen existing focused cases in `core_contract.ml`.

Expose one `scenario` value from each bad-case module and aggregate those values
in `Core_contract.scenarios`, preserving the existing `pure core` Alcotest group
and the exact case names and ordering.

Update the existing `test_sync` Dune stanza to compile the eleven new modules.
Do not add standalone executables, restore obsolete paths, modify production
code, or weaken source-boundary assertions.

## Decision

Adopt the proposed eleven-module test layout while preserving the unified test
runner, exact scenario names, and scenario ordering.

## Alternatives considered

### Restore the obsolete standalone executable paths

This would conflict with the current source-boundary contract and revive names
associated with removed pre-overlay fixtures.

### Create ten standalone Alcotest executables

This would require duplicated runner stanzas and separate test groups. Keeping
the modules in `test_sync.exe` preserves one discoverable `pure core` suite and
focused numeric selection.

### Leave shared fixtures in `core_contract.ml`

That would create a module dependency cycle because `core_contract.ml` must
aggregate each bad-case module's `scenario` value.

## Acceptance criteria

- BC01 through BC10 each live in one distinct `.ml` file.
- Shared bad-case setup lives in one support module and uses only public reducer
  and overlay APIs.
- `core_contract.ml` no longer defines any `bad_case_XX` function or bad-case
  fixture record.
- `Core_contract.scenarios` still exposes exactly eleven restored cases followed
  by the fifteen existing focused cases.
- The canonical happy path remains in `core_contract.ml`.
- The ten obsolete `test_pure_reducer_bad_case_*` paths remain absent and
  forbidden by `test/source_boundary_test.ml`.
- No production implementation or public specification changes.
- `dune exec logseq_sync/test/test_sync.exe -- test '^pure core$'`,
  `dune runtest logseq_sync/test`, `dune build @all`, `dune build @fmt`,
  `git diff --check`, and `spec-dev-tool check --all` pass.

## Risks

- Shared support can become an implicit testing API; keep it limited to causal
  fixture construction and exact public observations.
- Module ordering mistakes in the Dune stanza can prevent compilation even when
  individual case bodies are unchanged.
- Moving code can accidentally weaken a case if its exact assertion or retained
  owner probe is omitted.

## Consequences

- Each ownership failure path can be reviewed and selected from a file whose
  name matches its BC number.
- Bad-case setup is intentionally shared through one test-only support module.
- `core_contract.ml` remains the suite aggregator and retains the canonical
  happy path plus the pre-existing focused reducer cases.
- The unified `test_sync.exe` runner and its `pure core` group remain unchanged
  from a test consumer's perspective.

## Implementation

- Added `pure_reducer_bad_case_support.ml` for shared observations, tokens,
  graph values, and causal fixture construction.
- Added `pure_reducer_bad_case_01.ml` through
  `pure_reducer_bad_case_10.ml`, each exporting exactly one `scenario` value.
- Documented each bad-case module with its invalid event, required rejection,
  and retained-owner follow-up scenario.
- Removed the ten inline bad-case functions and their fixtures from
  `core_contract.ml`, then aggregated the new scenario values in the same
  order.
- Registered the eleven new test modules in the existing `test_sync` Dune
  stanza.

## Verification evidence

- `dune exec logseq_sync/test/test_sync.exe -- list` lists BC01 through BC10 in
  their original order.
- `dune exec logseq_sync/test/test_sync.exe -- test '^pure core$'` passes all
  26 pure-core tests.
- `dune runtest logseq_sync/test` passes all 38 sync tests.
- `dune build @all` and `dune build @fmt` pass.
- Static path checks find exactly ten numbered bad-case modules, no inline
  `bad_case_XX` definitions, and no obsolete
  `test_pure_reducer_bad_case_*` files.

## Questions

None. The user explicitly requested one `.ml` file per bad case.
