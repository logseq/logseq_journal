# 2026 10 23 Diagnostics Sync Cursors

## Problem

Diagnostics does not show the local applied sync checkpoint beside the latest known remote server cursor, making authoritative validation failures difficult to assess.

## Decision

Add Local tx and Remote tx rows to the existing Diagnostics groups. Local tx is the committed applied_server_t; Remote tx is the maximum current-graph cursor observed from snapshot metadata, Hello/Changed, admitted Pull responses, valid acceptance barriers and valid rejection cursors. Keep its observation independent of pull work so failures and completed pulls retain useful diagnostics. Display unknown values explicitly and clear observations on graph/account scope changes. Preserve int64 formatting and all existing diagnostics. No synchronization policy, protected interface, Dune, database format or transport changes.

## Alternatives considered

### Reuse transient pull work

Rejected because pull demand can disappear after catchup or failure, while the last observed server cursor is still useful.

## Acceptance criteria

- Public reducer tests demonstrate unknown values, exact int64 values, monotonic remote observation, commit-only local progress, diagnostics publication, error retention, and scope clearing with stale-message rejection.
- Existing diagnostic rows remain available and sync instructions retain their existing policy.

## Risks

- Remote tx is the latest observed server cursor, not a live query. Values may be unknown before the current graph receives server evidence.
- This change diagnoses an integrity failure; it does not fix or bypass the validation.

## Questions

- None. The user explicitly requested these two business sync cursors without a synchronization algorithm change.

## Consequences

The private reducer retains a typed, graph-scoped remote observation and projects both business cursors into the existing diagnostics groups. Diagnostic-only updates publish even when an existing pull is occupied; other synchronization instructions and their ownership remain unchanged. The LUI service forwards all groups and the application renders all nonempty groups, so no Swift or application view change is needed.

Four new public reducer cases cover unknown values, exact int64 maxima, remote notifications and failed synchronization, graph/account fencing, commit-only local advancement, metadata before snapshot activation and stale rejection evidence. Existing canonical flow assertions now include the new rows and diagnostic publications, including acceptance evidence. The initial two cases and the additional metadata/rejection cases each failed for missing application behavior before implementation.

All 309 sync tests pass, including synthetic loopback transport tests. The native app library and worker reducer/diagnostic service executables compile; the 20 worker reducer cases and diagnostic service suite pass. There is no Simulator, physical device, screenshot, live service or user graph validation. The first restricted loopback run could not bind ::1; the authorized rerun passed. An intermediate run from the external evidence directory could not locate source for an existing source-check test; the final run used the repository root with external logs and passed. Temporary build outputs and all evidence remain outside this repository.

The full decision-document check retains five pre-existing unrelated format failures; this decision passes its individual check. No commit, push, PR, database modification or release was performed.
