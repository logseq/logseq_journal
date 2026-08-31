# Pure Reducer Bad Case Tests

## Problem

`Logseq_sync_pure_reducer.Core.step` correctly rejects several stale token,
runner, graph, and connection events, but other asynchronous inputs are admitted
with only a broad graph or connection equality check. Some worker callbacks are
accepted without any corresponding pending operation, snapshot progress is
published without a current download owner, and `Restore_local_account` retains
runner ownership from the previous account generation.

These gaps permit invalid traces to change public state or emit new worker and
network instructions. In particular, duplicate callbacks can restart graph
attachment or pulling, a message received after WebSocket closure can fail the
current graph, an unsolicited authoritative result can replace the cursor and
outbox, and a catalog completion issued for one account can be applied after a
different account begins local restoration.

The existing `test_pure_reducer_canonical_happy_path` establishes exact causal
ownership for the successful trace, but it deliberately excludes stale,
duplicate, wrong-owner, and unsolicited events. Focused negative tests are
needed to document the suspected defects without changing reducer behavior.

## Proposal

Add ten standalone OCaml bad-case executables under `logseq_sync/test`, with one
bad case per `.ml` file. Each case must use only the public pure-reducer API,
construct its origin through a causally connected sequence, and assert the
semantic result independently of implementation output.

The files cover these suspected defects:

1. snapshot download progress for an unowned graph is published from the
   initial state instead of being ignored;
2. a duplicate `Mirror_inspected` callback after graph attachment emits another
   `Attach_graph` instruction;
3. a duplicate `Graph_attached` callback after attachment restarts
   `Connecting` and requests another WebSocket token;
4. a duplicate `Websocket_opened` callback for an already live connection emits
   another opening pull;
5. a WebSocket message delivered after `Websocket_closed` is still accepted by
   the unchanged connection generation;
6. an unsolicited `Authoritative_batch_applied` callback with the current graph
   scope replaces reducer state without an active authoritative owner;
7. `Restore_local_account` retains an earlier account's pending catalog ticket,
   allowing its late completion to populate the new account's catalog;
8. graph token challenge IDs are reused within one graph generation, allowing a
   response to a rejected challenge to satisfy a later challenge;
9. an unsolicited `Local_batch_committed` callback injects durable outbox data
   and reserves a submission without a preceding local-batch operation; and
10. an `Outbox_transition_committed` callback whose durable outbox differs from
    the reserved transition still dispatches the transaction.

Follow the canonical happy-path test style at the relevant scale:

- name every setup and bad transition;
- derive tokens, tickets, scopes, worker requests, and WebSocket connections
  only from previously checked effects in the same file;
- check the origin before and after `step` to prove immutability;
- replay the same `step` call to prove determinism;
- use static expected public state and ordered effects rather than copying the
  reducer's observed output; and
- make the final failing assertion identify the ownership rule being violated.

Do not modify `Core.step`, any other reducer implementation, files under
`logseq_sync/spec`, or any Dune file. Because the repository's test stanza has an
explicit module list and Dune edits are out of scope, compile and execute each
standalone bad-case file with a temporary external verification harness. The
regular `logseq_sync/test` suite remains the regression baseline and is expected
to stay green; every new bad-case executable is expected to compile and fail for
the documented reducer behavior.

## Decision

Adopt the ten standalone RED tests described above. Keep them outside the
explicit Dune module list so the repository's green regression alias continues
to represent supported behavior while each new executable independently records
one confirmed reducer defect.

Treat an asynchronous reducer input as owned only when it is causally related to
the exact capability or pending worker operation emitted earlier in the same
trace. Current graph or connection equality alone is not sufficient for a
duplicate, delayed, mismatched, or unsolicited callback.

## Alternatives considered

### Add the cases to `core_contract.ml`

This would run them under the existing test stanza, but it conflicts with the
requested one-file-per-bad-case layout and would mix deliberately failing defect
confirmations into the green contract suite.

### Modify `logseq_sync/test/dune`

Adding ten test stanzas would make the bad cases directly runnable by Dune, but
repository instructions explicitly prohibit Dune changes for this development
work. An external temporary harness proves that the files compile and fail
without changing the project build graph.

### Test every event constructor against every state

The earlier exhaustive matrix demonstrated that a broad cross product can encode
implementation behavior without proving causal ownership. These cases instead
use minimal traces selected from concrete ownership failures found by code
inspection.

### Fix the reducer while adding tests

That would complete a RED-GREEN cycle, but the requested scope is defect
confirmation only. The tests intentionally remain RED until a later bugfix
decision changes the reducer.

## Acceptance criteria

- Ten new `.ml` files exist directly under `logseq_sync/test`, one bad case per
  file.
- No production reducer, specification, or Dune file is modified.
- Every setup capability is derived from an earlier checked effect in the same
  file.
- Every bad case checks immutable origin, deterministic replay, exact expected
  public state, admitted graph scope, and ordered effects.
- Every standalone file compiles against the current public
  `Logseq_sync_pure_reducer` interface.
- Every standalone executable fails at the intended semantic assertion, not due
  to a syntax error, linkage error, fixture error, or unexpected exception.
- The existing `dune runtest logseq_sync/test` suite remains green.
- `ocamlformat --check` passes for all new files.
- `spec-dev-tool check --all` and `git diff --check` pass.

## Risks

- Deliberately failing files cannot be added to the default green test alias;
  consumers must run them explicitly until each corresponding reducer defect is
  fixed.
- Standalone files repeat a small amount of setup so each bad case remains
  independent. This is intentional test isolation rather than a new shared
  compatibility layer.
- Some callbacks originate from a trusted worker in production, but reducer
  serialization still permits duplicate, delayed, or reordered delivery. The
  cases assert causal ownership rather than treating malformed external data as
  the only threat model.
- The current public callback payloads do not expose explicit operation IDs for
  every worker action. A later fix may need private pending-owner state or a
  separately approved specification change; this testing decision does not
  choose that implementation.

## Consequences

- Each suspected defect has a small, reviewable, reproducible RED test.
- The files document the expected fail-closed behavior at the public `step`
  boundary without changing current runtime behavior.
- A later bugfix can turn over one case at a time and decide when to integrate it
  into the default Dune suite.

## Questions

None. The requested scope, file layout, and no-implementation-change constraint
determine the testing boundary.

## Implementation

Added `test_pure_reducer_bad_case_01_unowned_snapshot_progress.ml` through
`test_pure_reducer_bad_case_10_mismatched_outbox_commit.ml` directly under
`logseq_sync/test`. Each file is a standalone Alcotest executable with one test
case, local public-API-only fixtures, causally extracted capabilities, static
state expectations, ordered-effect checks, origin immutability checks, and
deterministic replay checks.

No reducer implementation, specification, existing test, or Dune file changed.
The default suite therefore remains green, while an external temporary build
harness compiles and runs the intentionally RED executables one at a time.

## Verification evidence

- All ten standalone files compile and link against the current public reducer
  interface.
- All ten executables exit with status 1 at their intended semantic assertions:
  BC01 publishes unowned progress; BC02 emits a duplicate attach; BC03 rewinds a
  live graph to connecting; BC04 emits a duplicate pull; BC05 accepts a message
  after close; BC06 accepts an unsolicited authoritative apply; BC07 installs an
  old account catalog after restore; BC08 starts a WebSocket from a stale token
  request; BC09 reserves an unsolicited outbox submission; and BC10 dispatches a
  mismatched durable outbox result.
- `dune runtest logseq_sync/test` passes.
- `dune build @all` passes.
- `ocamlformat --check` passes for all ten new files.
- `spec-dev-tool check --all`, `git diff --check`, and trailing-whitespace checks
  pass.
