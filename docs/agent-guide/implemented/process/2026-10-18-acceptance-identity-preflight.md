# Acceptance Identity Preflight

## Problem

A screenshot taken on a similarly named graph, stale installed App or another device
cannot prove the requested change. Handwritten actual identity fields repeat an
assumption instead of observing the running application.

## Decision

This records the initial preflight commit ca21d6c. The subsequently authorized
Simulator runtime bridge is specified separately in
`docs/agent-guide/implemented/architecture/2026-10-18-simulator-runtime-identity-bridge.md`.
The working implementation now adds that opt-in observer; real App/socket/display
integration remains unverified until a coordinated synthetic capture succeeds.

Use tool/capture_acceptance.py as the sole acceptance capture entry point. Compare
explicit expected Simulator UDID, device type, bundle, version/build, source commit
and graph UUID with fresh system/build evidence. Verify the maintained builder's
successful manifest against source files, packaged files and the freshly resolved
installed bundle. Reject unknown or inconsistent identities and suppress raw
command output. Keep evidence outside the repository.

At the initial commit, the App had an internal Get_graph_state query but no external
running-process bridge. The production observer therefore fails closed with
runtime-identity-unavailable. A documented challenge/response contract defines
that follow-up interface; fixture injection exists only in tests, never as a CLI
actual-identity option. This PR does not implement or claim real graph acceptance.
No App/HTTP/UI/protected spec or Dune changes belong to this work.

## Alternatives considered

### Graph name, manually supplied actual UUID, persisted selected graph

Rejected: names collide, constants are unverified and disk selection need not be
the graph currently open in the foreground process. Direct database/secret reads
are outside the permitted observation boundary.

## Acceptance criteria

- Synthetic command/filesystem tests cover identities, stale installs, graph
  transitions, failed/timed-out captures and privacy. Tests fail before implementation.
- Production capture blocks until a supported runtime observer is implemented.
- Guides require stable identity before UI operations and distinguish experimental
  host restamping, Simulator acceptance and real-device acceptance.
- Independent review and formal separate PR; exact-head CI tracked to terminal state.

## Consequences

- At that initial commit the runtime bridge was absent: this tool cannot yet produce a real
  accepted screenshot. The follow-up must bind Worker graph state to the mounted
  foreground presentation, process instance and monotonically changing generation.
- Local build manifests are provenance receipts, not cryptographic attestations
  against a malicious local author. Actual bytes and Git source are rechecked.
- Screen pixels can contain graph content. Evidence stays private unless reviewed;
  public tests and examples use synthetic identities only.

## Validation and scope

- 30 synthetic command/filesystem/CLI tests pass, including explicit failing
  tests before implementation and before the argument privacy/PNG fixes.
- The command boundary owns this preflight; App pure reducer tests cannot execute
  installed-container or screenshot failures. No App state ownership was moved.
- The runtime observer remains deliberately unimplemented and blocks production
  capture; no actual Simulator, graph or phone operation was performed.
- Independent read-only review found one argument-error privacy issue; a failing
  regression preceded the fix. The reviewer reran all 30 tests and confirmed the
  issue fixed with no new evidenced findings.
- New decision validation and diff whitespace checks pass. Full document checks
  retain three existing invalid historical documents outside this change.

- Resolved: user authorized this implementation and separate formal PR on
  2026-10-18, relayed with explicit evidence by the parent task.
- Resolved: the active status task owner retains exclusive Simulator
  installation/UI access; this task runs fixtures only and never touches iPhone47.
- Resolved: missing external runtime graph observer is a reported follow-up scope,
  not permission to accept a supplied actual UUID or read a database.
