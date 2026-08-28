# Reduce Logseq Sync Tests To Ten

> The fixed scenario-count invariant is superseded by
> `2026-08-27-logseq-sync-e2ee-roundtrip.md`. `source_boundary_test` no longer
> asserts a test count. The Alcotest, package-ownership, dependency, and fixture
> boundaries in this decision remain active.

## Problem

`logseq_sync/test` currently registers 16 test executables containing 94 named or
top-level scenarios across 4,784 lines of OCaml test code, including the shared
test-support module. The focused suite currently passes with:

```sh
dune runtest logseq_sync/test
```

The requested end state is exactly ten test scenarios across the entire
`logseq_sync` package. The limit applies to scenarios, not Dune executables.
Downstream `logseq_db_worker` integration scenarios are outside this count and
remain required validation of the upper package's composition with sync.

The current suite also fails to enforce the package boundary it is meant to
protect. All 16 executables are declared in one Dune `tests` stanza whose
libraries include both `logseq_db_worker` and
`logseq_db_worker_test_support`. Test code introduces four additional reverse
dependencies:

- `test_manager.ml` contains a worker `Config` serialization scenario and reads
  worker protocol limits.
- `test_replay.ml` imports worker-owned adapter and structural fixture helpers.
- `test_tx_checksum.ml` imports the worker-owned structural fixture helper.
- `test_support.ml` resolves every pinned sync fixture through
  `logseq_db_worker/test/fixtures/sync`.

Most tests exercise sync-owned behavior and do not need the worker. The shared
Dune stanza nevertheless makes even isolated tests link the worker. This is the
opposite of the intended ownership direction: an upper worker package may test
its integration with sync, but a sync-owned test must not import or link the
worker.

The suite also implements its own minimal framework in `test_support.ml` through
the custom `case`, `run`, `require` and `fail` functions. It aggregates failures
but does not provide standard Alcotest case selection, structured assertion
rendering or uniform test reporting. Keeping a custom runner would make the exact
ten-scenario budget harder to inspect and enforce.

### Current inventory

| Executable | Current scenarios | Principal behavior | Reduction decision |
| --- | ---: | --- | --- |
| `test_auth` | 3 | One-shot token challenges, identity and generation fences, secret-free diagnostics | Consolidate the strongest assertions into scenario 3 |
| `test_bootstrap_transport` | 5 | Strict metadata, bounded gzip peeling, cleanup, decompression limits and HTTP backpressure | Consolidate into scenario 10 |
| `test_capabilities` | 5 | Scope-sealed and one-shot startup/recovery capabilities | Consolidate into scenario 3 |
| `test_catalog` | 3 | Strict catalog decoding, ready-entry filtering, selection and mirror state | Retain strict remote-input behavior in scenario 4; remove local bookkeeping checks |
| `test_catalog_store` | 1 | Cache persistence and account/origin scoping | Remove |
| `test_e2ee` | 3 | Upstream key package, protected attributes and encrypted envelope | Consolidate into scenario 9 |
| `test_e2ee_session` | 4 | Cached-key unlock, password prompting and endpoint contracts | Consolidate into scenario 9 |
| `test_graph_key` | 1 | Key length, use, clear and use-after-clear rejection | Consolidate into scenario 9 |
| `test_manager` | 34 | Startup, graph selection, lifecycle, retries, reconnects, replay coordination, recovery and E2EE orchestration | Replace with scenarios 1 and 2 |
| `test_network_scope` | 2 | Cancellation callbacks across account and graph generations | Remove helper-level assertions; retain externally visible fencing in scenarios 1 and 2 |
| `test_pending` | 5 | Durable format, corruption, state transitions and obsolete-path deletion | Consolidate into scenario 7 |
| `test_protocol` | 8 | Deployed wire fixtures, strict decoding, presence, cursor/checksum validation and client encoding | Consolidate into scenario 4 |
| `test_replay` | 5 | Ordered replay, duplicates, malformed input, checksum pause and rollback | Consolidate into scenario 6 |
| `test_snapshot` | 4 | Framing fragmentation, bounds, row ordering and import validation | Consolidate into scenario 8 |
| `test_transport_ownership` | 4 | Endpoint construction, HTTPS/content-type policy, redaction and WebSocket handshake | Consolidate into scenario 10 |
| `test_tx_checksum` | 7 | Transit normalization, lookup references, pinned checksums and encrypted transaction round trips | Consolidate into scenario 5 |

`test_support.ml` is a support library rather than a scenario. It may remain only
with sync-owned fixture, temporary-directory and domain-construction helpers. Its
custom test runner and assertion API must be deleted in favor of Alcotest.

## Decision

Replace the 94 current scenarios with exactly ten risk-oriented scenarios. A
scenario may exercise several consecutive transitions or related negative cases,
but it must have one named behavioral claim and one setup/teardown lifecycle.

1. **Local-first startup remains usable and generation-fenced.** Restore a plain
   and an encrypted local mirror before authentication or network work, acknowledge
   the current Timeline generation, and prove stale timeline, graph-switch,
   sign-out and late-event inputs cannot activate or replace the selected graph.

2. **Foreground WebSocket reconciliation serializes recovery.** Exercise
   background disconnect, resume, token refresh, opening pull, changed-frame
   coalescing, probe timeout and uncertain-submission recovery in one lifecycle;
   prove no submission recovery or reconnect crosses a generation or precedes the
   authoritative opening pull.

3. **Authorization capabilities are one-shot and scope sealed.** Issue and consume
   an authentication challenge, reject identity/account/graph/connection
   mismatches without consuming it, prove recovery permits cannot cross scopes or
   be reused, and verify diagnostics contain no token material.

4. **Deployed remote contracts round trip and fail closed.** Decode the pinned
   protocol, duplicate-tx-id and catalog fixtures; validate cursor/checksum and
   ready-catalog semantics; encode the canonical client messages; reject unknown,
   malformed and Chat-only payloads.

5. **Transactions preserve pinned plaintext and E2EE checksums.** Decode canonical
   Transit operations including cached lookup references and retractions, apply
   them to a minimal sync-owned DataScript fixture, verify pinned checksums, and
   round-trip an outgoing protected value without exposing plaintext.

6. **Replay is atomic, idempotent and durably pauses on divergence.** Apply an
   ordered pull, prove duplicate replay is a no-op, reject a cursor gap without
   advancement, preserve the usable graph on checksum mismatch, and inject a
   checkpoint-write failure to prove KVS and metadata rollback together.

7. **Pending intents survive restart and reject invalid durable state.** Persist a
   versioned pending mutation, reopen it, advance its accepted state, reject
   corruption, and prove obsolete paths are deleted rather than migrated while
   the current path remains authoritative.

8. **Snapshot import is streaming, bounded and structurally strict.** Feed a pinned
   framed snapshot across prefix and payload boundaries, accept the expected
   ordered rows, and reject oversized, malformed, negative, duplicate, missing or
   incorrectly counted rows without completing the import.

9. **E2EE keys unlock, encrypt, clear and fail closed.** Unlock the pinned upstream
   package through both cached-private-key and password flows, enforce protected
   attributes and the upstream ciphertext envelope, reject malformed endpoint
   contracts, and prove a cleared graph key cannot decrypt or encrypt again.

10. **Bootstrap and live transport enforce bounded secure I/O.** Validate strict
    HTTPS bootstrap metadata, accept at most two gzip layers, reject oversized or
    deeper artifacts without residue, preserve a backpressured response, enforce
    endpoint/content-type policy and redaction, and prove WebSocket hello/pull
    ordering with generation fencing.

The scenarios should be grouped by ownership rather than preserving the current
file boundaries. A reasonable implementation uses fewer than ten executables,
with two manager scenarios and one scenario for each remaining risk area. Every
scenario must be registered with `Alcotest.test_case`, and every executable must
start its suites with `Alcotest.run`. The total can then be enforced by counting
exactly ten `Alcotest.test_case` registrations. Assertions must use Alcotest checks
or `Alcotest.fail`/`Alcotest.failf`; `test_support` must not wrap or recreate a
second test framework. Obsolete test files and helper paths are deleted after
their selected assertions are consolidated; no compatibility test aliases remain.

Remove every worker dependency from the resulting sync suite:

- Remove `logseq_db_worker` and `logseq_db_worker_test_support` from
  `logseq_sync/test/dune`.
- Add `alcotest` as a test-only dependency of `logseq_sync` in Dune and the
  package metadata, and regenerate the locked metadata through the repository's
  normal dependency workflow. Alcotest must not become a production library
  dependency of any `logseq_sync` sublibrary.
- Move the five pinned sync JSON fixtures from
  `logseq_db_worker/test/fixtures/sync` to `logseq_sync/test/fixtures` and make
  `test_support.fixture` resolve only within that directory.
- Add only the minimal DataScript schema and temporary-directory helpers needed
  by scenarios 5 and 6 to the sync test-support library. Do not copy the worker
  adapter fixture, expose a compatibility alias or retain the custom `T.case`,
  `T.run`, `T.require` and `T.fail` interfaces.
- Delete `test_managed_sync_startup_has_no_graph_target_or_credential`. It tests
  `Logseq_db_worker.Config`, so it is not a `logseq_sync` scenario and must not be
  moved or retained as part of this reduction.
- Leave downstream worker integration suites such as `test_sync_engine` and
  `test_sync_mirror` in `logseq_db_worker/test`. They do not count toward the ten
  sync scenarios, but remain required validation because an upper package may
  depend on and test `logseq_sync`.

## Alternatives considered

### Keep ten test executables

This interpretation would retain dozens of scenarios inside the ten executables
and would not meet the clarified requirement that only ten scenarios remain.

### Select ten existing scenarios without consolidation

The current scenarios are generally narrow. Selecting ten unchanged cases would
force entire independent risk boundaries to disappear, especially negative input,
failure atomicity and key-lifecycle coverage. The proposed ten scenarios combine
closely related positive and negative phases under one observable behavioral
claim.

### Keep all scenarios and only remove the worker link

Splitting Dune stanzas and replacing worker-owned fixtures would fix the package
boundary but would not reduce the 94-scenario maintenance surface.

### Keep the custom test harness

The current harness is small, but it duplicates case registration, failure
aggregation and assertions while offering less inspectable output. Alcotest gives
the ten scenarios one standard registration point and makes the scenario count,
selection and failure names visible without maintaining framework code in this
package.

### Count downstream worker integration scenarios in the ten

That would mix lower-package contract tests with upper-package composition tests
and make the sync budget depend on worker implementation breadth. Downstream
integration remains useful validation but is explicitly outside the count.

## Acceptance criteria

- The `logseq_sync` package registers exactly ten `Alcotest.test_case` scenarios
  with the ten behavioral claims listed above; no additional top-level assertion
  sequence can execute as an uncounted scenario.
- Dune may group the ten scenarios into fewer than ten executables, but every
  executable reports its cases through `Alcotest.run`.
- The custom `case` record, `T.case`, `T.run`, `T.require` and `T.fail` APIs are
  removed. Test-support code contains no runner, assertion framework or exception
  aggregation that duplicates Alcotest.
- `alcotest` is declared only for tests in the Dune/package dependency graph and
  appears in the regenerated package and locked metadata; production
  `logseq_sync` libraries do not link it.
- No source, Dune stanza, test-support module, fixture path or generated dependency
  owned by `logseq_sync/test` refers to `Logseq_db_worker`,
  `Logseq_db_worker_test_support`, `logseq_db_worker` or a worker-owned fixture.
- The five pinned sync fixtures are owned by `logseq_sync/test/fixtures`. The old
  worker fixture path is deleted after all consumers are updated; no fallback or
  duplicate compatibility path remains.
- The worker-owned managed-sync config scenario is deleted.
- Scenario 6 proves ordered atomic replay, duplicate idempotence, no advancement
  on a cursor gap, durable checksum pause and KVS rollback on checkpoint failure.
- Scenario 9 proves upstream E2EE compatibility, protected-value confidentiality,
  cached-key/password recovery, malformed-contract rejection and use-after-clear
  rejection.
- Scenario 3 proves one-shot authorization, identity and generation fencing,
  scope isolation and absence of token material in diagnostics.
- `dune runtest logseq_sync/test` passes and its output accounts for exactly ten
  scenarios.
- Dune dependency inspection proves none of the sync test executables has a direct
  or transitive dependency on `logseq_db_worker`.
- The package source-boundary test and downstream `test_sync_engine` and
  `test_sync_mirror` suites pass. Their scenarios are not included in the count of
  ten.

## Risks

- Combining multiple negative branches into one scenario reduces failure
  localization. Each phase needs a precise assertion message so a failure still
  identifies the violated invariant.
- Only ten scenarios means many implementation-detail regressions will no longer
  be detected directly. The retained set deliberately prioritizes data loss,
  credential leakage, protocol incompatibility, stale-generation effects and
  unrecoverable startup failures.
- Removing the catalog-store round trip makes cache serialization regressions
  detectable only through downstream or application-level tests.
- Removing direct network-scope callback counts makes manager outcomes, rather
  than helper implementation details, the maintained contract.
- A single scenario that tests too many unrelated facts can become brittle. The
  ten named claims are the maximum allowed scope; helpers may reduce setup, but
  assertions from omitted tests should not be accumulated merely to preserve old
  coverage.
- Alcotest's default output and exception handling differ from the custom runner.
  Every consolidated phase needs a stable case name and typed or explicit
  assertion message so the reduced suite remains diagnosable in local and CI
  output.
- Relocating pinned fixtures can break downstream worker tests if they currently
  assume the worker path. Every consumer must be enumerated before deletion; the
  resolution must establish one owner rather than add a fallback path.

## Consequences

`logseq_sync/test` now builds one Alcotest executable that registers exactly ten
risk-oriented cases. The retained scenario modules group related positive and
negative phases behind those registrations, while obsolete executables, runner
entry points and unselected manager, catalog, replay and checksum checks are
removed. Alcotest output makes the scenario count and names directly visible.

The sync test-support library now owns only fixture lookup, temporary-directory,
UUID and minimal DataScript schema helpers. It no longer defines assertions,
case records, failure aggregation or a runner. The sync test executable and its
support library depend on Alcotest, but no production sync library links it.

The five pinned sync fixtures now have a single owner under
`logseq_sync/test/fixtures`. Sync tests no longer import, link or resolve anything
from `logseq_db_worker` or its test-support library. A source-boundary check keeps
the ten-case budget, test-only dependency, fixture ownership and worker isolation
from regressing.

The reduced suite favors high-risk end-to-end claims over narrow localization.
A failure may therefore require reading the phase-specific Alcotest assertion
message inside a broader case. Downstream worker integration tests remain the
composition boundary for behavior that legitimately spans worker and sync.

## Questions

- None. The user confirmed that the limit is ten scenarios, the worker-owned
  managed-sync config scenario must be deleted, and downstream worker integration
  scenarios remain outside the count. The user also selected Alcotest as the
  required test framework.
