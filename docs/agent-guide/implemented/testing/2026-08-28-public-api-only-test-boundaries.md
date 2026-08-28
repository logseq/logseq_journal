# Public API Only Test Boundaries

## Problem

Tests currently bypass package interfaces and compile directly against wrapped,
unexposed implementation modules. This occurs through Dune-generated module
names such as `Logseq_sync__logseq_sync_impl__Manager` and
`Logseq_db_worker__Snapshot`. The `logseq_sync` suite additionally injects the
implementation object directories with `-I` flags:

```text
logseq_sync/lib/.logseq_sync_impl.objs/byte
logseq_sync/lib/.logseq_sync_impl.objs/native
```

These paths are implementation details rather than supported package contracts.
They allow a test to compile even when the tested behavior is intentionally
hidden from package consumers, couple tests to Dune's generated naming scheme,
and caused clean-build ordering failures when the private interfaces had not yet
been produced.

The production design does not require every module to be public. Private and
wrapped modules remain valid implementation boundaries. The problem is that a
test suite treats those boundaries as if they were public APIs.

The current direct-use inventory is:

- Fourteen files under `logseq_sync/test` import private implementation modules.
  They cover manager orchestration, authorization, remote contracts,
  transactions, replay, pending state, snapshots, E2EE, graph keys, bootstrap,
  HTTP, and WebSocket policy.
- Sixteen files under `logseq_db_worker/test` import unexposed worker modules
  such as `Mutation_plan`, `Graph_read`, `Graph_locator`, `Ownership`, `Snapshot`,
  `Backup`, `Query`, and `Outliner_order`.
- `test/journal_runtime_golden_fixture.ml` imports the unexposed worker
  `Snapshot` module.
- `logseq_db_worker/test/adapter_fixture.ml` imports the unexposed `Snapshot`
  module and is then consumed by public `Engine`, Bonsai service, application,
  CLI, and fixture-generator tests.

`test/source_boundary_test.ml` contains mangled names as forbidden-text literals;
those literals inspect source boundaries and do not compile against private
modules.

## Proposal

Adopt a repository-wide test rule: test executables and test-support modules may
depend only on interfaces exposed by the libraries in their Dune `libraries`
stanzas. A test must not name a Dune-generated wrapped-module path, add an
implementation `.objs` directory to the compiler include path, or make a
production module public solely to test it.

Delete tests whose behavioral subject is an unexposed implementation module.
Do not preserve them through aliases, test-only public re-exports, friend
libraries, copied interfaces, or compatibility wrappers.

For `logseq_sync/test`, remove the fourteen private-module scenario and contract
files, remove their registrations from `test_sync.ml` and `dune`, and remove the
two `.logseq_sync_impl.objs` include paths. Retain `api_contract.ml`, which drives
the public `Logseq_sync.Api` interface. Delete `test_support.ml` and its support
library if they become unused after the private scenarios are removed.

For worker tests, delete unit tests that directly exercise unexposed modules.
Mixed files must retain only cases that can be expressed through exposed modules
such as `Logseq_db_worker.Engine`, `Config`, `Protocol`, and `Graph_lifecycle`.
Delete private-module cases rather than exposing their implementation subjects.

Treat fixture and helper code as part of the test boundary. A helper may create
data with public APIs or plain fixture data, but may not bypass the package
interface. Public-API integration tests should be retained when their setup can
be expressed without private modules; otherwise their disposition is the open
question below.

Add a source-boundary assertion that scans test and test-support OCaml sources
for Dune-generated private module identifiers and scans test Dune files for
`.objs/byte`, `.objs/native`, and manual `-I` access to implementation object
directories. The assertion must exclude its own forbidden-text literals. The
rule applies to test-owned code only; existing production CLI and tool access is
outside this decision.

## Decision

Accept the proposal. Private production modules remain private, while tests and
test-support code are restricted to exposed package interfaces. Rewrite fixture
setup when doing so preserves public behavioral coverage; delete tests whose
subject is an unexposed module.

## Alternatives considered

### Publish every tested module

Rejected. Test coverage does not establish that a module is a supported package
contract. Publishing implementation modules would weaken encapsulation and was
not the requested boundary.

### Keep private tests with implementation include paths

Rejected. This preserves dependence on generated build paths and retains the
clean-build race that exposed the problem.

### Add a friend or test-only implementation library

Rejected. It would formalize a second API surface for implementation details and
retain tests whose subject is intentionally unexposed.

### Replace every deleted unit test immediately through the public API

Deferred. Observable risks should ultimately be covered at a public boundary,
but mechanically translating private unit assertions can preserve
implementation-shaped tests under different names. This decision first removes
the invalid dependency direction and retains existing tests that already use
public APIs.

## Acceptance criteria

- No test or test-support OCaml source compiles against a Dune-generated wrapped
  implementation path such as `Logseq_sync__logseq_sync_impl__*` or
  `Logseq_db_worker__*`.
- No test Dune stanza adds implementation `.objs/byte` or `.objs/native`
  directories with `-I`.
- `logseq_sync/test` retains public `Logseq_sync.Api` contract coverage and no
  direct tests of private sync modules.
- Worker tests retain only behavior exercised through exposed worker interfaces;
  direct tests of unexposed worker modules are deleted.
- No production module is exposed or aliased merely to preserve a deleted test.
- A source-boundary regression test enforces the test-only rule without banning
  private modules from production libraries.
- `dune build @all`, `dune runtest`, `dune build @fmt`,
  `spec-dev-tool check --all`, and `git diff --check` pass.

## Risks

- Deleting implementation-level tests reduces diagnostic precision and may
  remove coverage for protocol parsing, encryption, storage, replay, and
  outliner planning behavior that is not observable through current public APIs.
- Deleting all consumers of a private fixture helper could remove valuable
  public integration coverage even when only the setup path violates the rule.
- A lexical mangled-name check is intentionally strict and may require a narrow
  exclusion for the boundary test's own forbidden literals.
- Production CLI and tool code still names unexposed worker modules; that is not
  test coverage and remains outside the scope of this testing decision.

## Consequences

The test suite loses implementation-level diagnostic coverage and retains a
smaller set of contract and integration tests. Public behavior tests no longer
depend on Dune-generated module names or implementation object paths, so clean
build ordering and refactoring of private modules cannot affect their imports.
Future implementation risks must be tested through an existing public contract
or motivate an independently justified API decision.

## Implementation outcome

Implemented on 2026-08-28.

- The fourteen `logseq_sync` implementation-level scenario and contract files
  were deleted. `test_sync` now runs the four cases in `api_contract.ml` through
  `Logseq_sync.Api` only.
- The sync test-support library, its unused fixtures, and both manual
  `.logseq_sync_impl.objs` include paths were deleted.
- Twelve worker unit-test files whose subjects were unexposed implementation
  modules were deleted from the source tree and Dune test stanza.
- Retained worker, CLI, application, and golden tests now build snapshots through
  the public `Cli_command.create_snapshot` entry point and validate them through
  public `Engine` or CLI behavior.
- Mixed `Engine` tests no longer call `Ownership` or `Query` internals. The
  ownership cleanup assertion now reopens the public `Engine`, and the cursor
  test retains only the public cross-query rejection behavior.
- `source_boundary_test` scans all OCaml test and test-support sources for
  Dune-generated internal module names and rejects test Dune stanzas that add
  implementation object directories.

## Questions

- Resolved: when a test verifies public behavior but its fixture setup currently
  uses an unexposed module, rewrite the fixture setup through public APIs and
  retain the public-behavior test. Delete only assertions whose subject is the
  private module.
