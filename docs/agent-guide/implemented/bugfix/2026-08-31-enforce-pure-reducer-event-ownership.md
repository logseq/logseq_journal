# Enforce Pure Reducer Event Ownership

## Problem

`Logseq_sync_pure_reducer.Core.step` admits several asynchronous events by broad
graph or connection scope alone. It does not consistently require the exact
pending operation or live transport state that caused the event.

Ten executable bad-case tests demonstrate the consequences. The reducer
publishes unowned snapshot progress, repeats mirror attachment and WebSocket
opening work, accepts messages after a WebSocket closes, consumes an old
account's catalog completion, reuses a graph-token challenge identity, and
accepts unsolicited or mismatched worker commit results. These transitions can
change durable synchronization state or emit network and worker instructions
without a current causal owner.

## Proposal

Make asynchronous event admission fail closed inside the existing private
reducer state without changing the public specification.

- Publish snapshot progress only while the current graph owns an active
  snapshot download.
- Record and consume mirror-inspection, graph-attachment, and local-commit
  ownership when their corresponding worker instructions are emitted.
- Accept WebSocket-open only once per current connection, and accept WebSocket
  messages and protocol errors only while that connection is live.
- Accept authoritative apply results only while an authoritative batch is
  active.
- Clear previous runner tickets when local account restoration replaces the
  account generation.
- Mint a fresh opaque graph-token request ID for each challenge while preserving
  the established first-challenge ID shape.
- Record the exact reserved outbox transition and require a commit result to
  match it before consuming the reservation, changing state, or sending the
  transaction. A mismatched result leaves the exact reservation available for a
  later matching completion.

Keep the production change limited to `logseq_sync/lib/pure_reducer/core.ml`,
plus removing the now-obsolete `Current bug` lines from the ten bad-case test
comments. Update older contract fixtures that directly injected newly forbidden
callbacks so they construct the same states through owned reducer traces. Do not
modify public `.mli` files, Dune files, or unrelated modules.

## Decision

Adopt private reducer ownership records and live-transport gates for the ten
asynchronous bad cases. Callback facts must match the current causal owner before
they can change state or emit instructions. Keep the public reducer interface
unchanged.

## Alternatives considered

### Alternative

Add operation IDs to every public callback in `core.mli`. This is not selected
because the existing callback payloads contain enough immutable scope and result
data to enforce the tested ownership rules with private pending state. A public
API expansion would exceed the requested bugfix and is not required by the ten
tests.

## Acceptance criteria

- All ten `test_pure_reducer_bad_case_*` executables pass.
- The existing pure-reducer and sync contract tests remain green.
- Duplicate, stale, unsolicited, closed-transport, and mismatched events are
  deterministic no-ops and do not consume valid pending ownership.
- Valid owned callbacks continue to make progress exactly once.
- The ten test scenario comments no longer contain a `Current bug` description.
- OCaml formatting, repository build, whitespace checks, and
  `spec-dev-tool check --all` pass.

## Risks

- The current callback API cannot distinguish two concurrently pending local
  commits with identical graph scope and durable outbox payloads. The reducer
  therefore matches the immutable callback facts exposed by the existing
  specification and consumes only one matching owner. If the runtime later
  permits indistinguishable concurrent commits, the public callback contract
  will need an explicit operation identity.

## Consequences

- Duplicate, stale, unsolicited, and mismatched callbacks are deterministic
  no-ops at the pure reducer boundary.
- Valid mirror, graph, local commit, authoritative, and outbox completions remain
  one-shot and continue to advance the synchronization flow.
- Test setup code must construct owned callback traces instead of injecting
  completion events directly into broadly matching graph states.
- No public API, Dune configuration, effect-runner contract, or specification
  file changes are required.

## Questions

None. The ten tests define the required behavior, and the existing private state
can enforce it without a specification change.

## Implementation

The reducer now tracks pending mirror inspection, graph attachment, and local
commit facts in private immutable state. It consumes matching worker callbacks
once, clears those owners at account and graph boundaries, and ignores callbacks
without a matching owner. Snapshot progress is admitted only during the current
graph's download phase.

WebSocket open is one-shot, and messages and protocol errors require a live
current connection. Authoritative apply requires an active current batch. Local
account restoration clears earlier runner tickets before issuing the new catalog
load.

Graph-token challenges use a monotonic private nonce after the established first
challenge ID. Submission owners retain the exact reserved durable outbox, and an
outbox commit changes state only when its payload and message match the
reservation; mismatches leave the owner intact for a later exact completion.

The older core contract fixtures now reach authoritative-current and local
commit states through `Websocket_message`, authoritative inspection, and
`Local_batch_prepared` ownership. The ten bad-case scenario comments no longer
contain `Current bug` lines.

## Verification evidence

- All ten `test_pure_reducer_bad_case_*` executables pass.
- The existing `test_sync.exe` suite passes all 53 tests.
- `dune runtest logseq_sync/test` and `dune build @all` pass.
- `ocamlformat --check`, `git diff --check`, staged whitespace validation, and
  the explicit absence check for `Current bug` all pass.
- `spec-dev-tool check --all` passes.
