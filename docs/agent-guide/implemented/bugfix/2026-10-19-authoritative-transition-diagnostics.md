# Authoritative Transition Diagnostics

## Problem

The installed a0746e97 worker discards begin_authoritative error variants and
publishes one generic rejection with Storage_busy. The Worker errors publisher
then replaces every authoritative failure with one generic ledger entry.
This prevents distinguishing closed databases, sync-version conflicts,
discontinuous cursors and unsupported transaction formats.

## Decision

Keep the existing overlay variants and worker Error codes. Use one pure
authoritative transition error mapper in the effect runner, shared by begin and
apply. All messages and diagnostic category signals must be fixed strings;
discard raw decode, integrity, persistence and fatal-state text.
Preserve the category through the existing reducer Diagnostic signal and the
service's finite allowlist, so Last error and Worker errors both distinguish it.
Do not change recovery, synchronization policy, protected types, Dune, account
access, phone installation or graph data.

The runner mapper stays private. Deterministic runtime tests will exercise actual
cursor and format rejection through Runner and Core, without fabricated producer
results. Separate propagation tests cover all four typed errors at the reducer
boundary, and the service's existing pure diagnostic row projection is exported
through its ordinary (non-spec) mli for direct tests of the actual UI allowlist.
These propagation tests do not claim producer coverage of close/token races.
The two deterministic producer races remain explicitly uncovered because the
existing public runner interface has no such scheduling boundary. No protected
spec or Dune change is made.

## Alternatives considered

### Only replace the runner message

Rejected because Worker errors would still normalize every failure. Mapping tests
that inject hand-written worker errors would not verify producer classification.
Adding a second error enum or moving overlay policy into the contract would add
unnecessary coupling and potentially require prohibited Dune changes.

## Acceptance criteria

- All four begin-authoritative variants have distinct fixed messages and accurate
  existing worker Error codes; only genuinely busy states use Storage_busy.
- Producer mapping and actual downstream diagnostics projection are covered by
  deterministic tests where publicly reachable, including raw-sensitive-string exclusion.
- Existing source and public type boundaries are respected; production code
  changes require no protected-interface extension.
- A real Web/Simulator reproduction must use the same verified dedicated graph,
  ordinary UI edits and authenticated production synchronization, not worker injection.

## Risks

- Discarding raw lower-level messages intentionally limits detail to safe categories.
- Host-restamped Simulator builds retain cross_abi_validated=false.
- The current 1446 ordinary App has no authenticated session. Its normal Cognito
  login form requires credentials unavailable in the configured environment.
  No credentials or tokens may be copied from the Mac browser.

## Questions

- None for the authorized implementation. Explicit parent direction on 2026-10-19
  keeps the producer mapper private, accepts the honest deterministic coverage gap,
  and forbids modifying protected interfaces. Simulator authentication and any
  future producer test-interface extension remain separate pending user actions.

## Consequences

The private shared mapper now emits fixed messages and origin categories using
existing Error codes. Only actual prepare/commit busy variants use Storage_busy.
Checksum/integrity/persistence use the broad Ambiguous_sync_state code with their
exact fixed origin category; a fatal-state commit closes the database and uses
Closed_session. Neither ownership failure nor disk corruption is inferred.
Core retains the origin category in its Diagnostic signal. The service's finite
allowlist retains that category in the existing applyAuthoritative ledger row.
No recovery, retry, commit, graph, authentication or asset behavior changed.

Three actual runner/database rejection cases failed against the old uniform
Storage_busy result and passed after the change. Four-category downstream
propagation and the actual service row allowlist also failed before and passed
afterward. The producer mapper remains private: database-close and sync-version
preparation races have no deterministic public hook and are not claimed covered.
The service projection test is compositional coverage, not mounted UI acceptance.

A clean full @all build and forced full runtest passed: 21 Alcotest suites,
977 cases, plus standalone programs. The new decision passes validation; the
whole document check retains four pre-existing invalid historical documents.
Independent review's two classification findings were corrected and final diff
review found no further blockers. All temporary evidence is outside the repo.

An external synthetic probe uses real Runner/Database commits and only delays
consumption of their actual completion. Its control consumes checkpoint 1;
backgrounding before consumption instead leaves the manager at 0 while SQLite
is durably at 1. Foreground plus a normal repeated pull then actually rejects
cursor 1 as authoritativeCursorDiscontinuous. No completion is fabricated and
no product recovery fix was made. This proves a local client race path, not
real Web synchronization or the cause of the user's phone screenshot.

The Mac Web test graph is verified online with local/remote tx 872 and no edits
submitted. Existing Simulator 1446 lacks a logged-in ordinary Journal session;
its normal Cognito login form requires user input. No credentials were copied,
no iPhone was used and no graph was deleted. Protected spec and Dune files remain
unchanged. Simulator packaging, if prepared later, retains experimental ABI limits.
