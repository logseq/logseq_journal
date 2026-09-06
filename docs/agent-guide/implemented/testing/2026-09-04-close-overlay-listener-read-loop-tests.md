# Close Overlay Listener Read Loop Tests

## Problem

`logseq_overlay_db` tests notification and logical projection behavior, but no
single test closes the public consumer loop from a durable overlay transition to
a listener notification and then to a read from the published successor
snapshot.

The current coverage is split across suites:

- `test_overlay_changes.ml` proves that a local commit, an outbox rejection, and
  an authoritative insertion publish the expected `Exact` notification.
- `test_overlay_mutations.ml` proves that optimistic outbox content is visible
  through public reads.
- `test_overlay_sync.ml` proves that authoritative application and outbox
  rollback produce the expected logical data.

Those tests can all pass if the change summary and the published logical root
drift apart. For example, a transition could publish the correct affected UUIDs
but expose stale data from `Database.current_snapshot`, or it could publish the
correct successor root without notifying a listener that depends on the
affected block or structure scope.

The missing contract is the behavior used by an incremental consumer:

```text
listen and retain predecessor revision
                |
                v
apply authoritative or outbox transition
                |
                v
receive one adjacent logical change
                |
                v
acquire successor snapshot and read affected data
```

The test must exercise only the public `Logseq_overlay_db.Database` interface.
It must not inspect Datascript connections, private overlay roots, persistence
rows, or implementation modules.

## Proposal

Add closed-loop cases to
`logseq_overlay_db/test/test_overlay_changes.ml`, beside the existing merged
logical listener tests. Keep the existing focused tests; the new cases verify
the cross-boundary relationship rather than replace lower-level coverage.

Use a small test-local helper that:

1. Calls `Database.listen` and records the returned predecessor snapshot
   version.
2. Releases the predecessor, activates the subscription, and applies one
   transition.
3. Awaits one notification and requires `Exact`.
4. Proves that `before_revision` equals the predecessor projection revision and
   `after_revision` equals the transition result's projection revision.
5. Acquires `Database.current_snapshot` only after receiving the notification.
6. Proves that the acquired snapshot has the notified `after_revision`.
7. Reads the affected entities and structure through `Database.get_blocks` and
   `Database.get_structure`.
8. Releases the snapshot and unlistens through cleanup paths even when an
   assertion fails.

The helper must not assume that a callback may safely perform database reads.
The callback should resolve an `Eio.Promise`; the test fiber should acquire and
read the successor snapshot after awaiting that promise.

### Required case A: optimistic outbox publication

Add a case named
`local outbox commit notifies and successor snapshot is readable`.

The case should commit one `Insert_blocks` mutation and verify all of the
following:

- `commit_local` returns `Local_committed` with status `Applied`.
- The listener receives exactly one adjacent `Exact` notification.
- The notification contains the inserted block UUID, affected page UUID,
  `Children_interest` for the parent page, and `Page_tree_interest` for the
  page.
- The successor snapshot contains the inserted block with the expected title,
  parent, page, and optimistic revision.
- A children read for the parent contains the inserted block in the expected
  order.
- `Database.inspect_sync` contains the mutation as a queued submission, proving
  that the visible logical data came from pending outbox intent rather than an
  authoritative write.

### Required case B: authoritative publication

Add a case named
`authoritative update notifies and successor snapshot is readable`.

The case should apply one authoritative transaction that inserts a remote child
under the fixture page and verify all of the following:

- `apply_authoritative` returns `Authoritative_applied` and advances the server
  checkpoint.
- The listener receives exactly one adjacent `Exact` notification.
- The notification contains the remote block UUID, affected page UUID,
  `Children_interest`, and `Page_tree_interest`.
- The successor snapshot contains the remote block with the expected decoded
  title, parent, page, order, and timestamps.
- A children read for the parent contains the remote block in the expected
  position.
- `Database.inspect_sync` exposes the new checkpoint and no unexpected outbox
  state.

### Required case C: authoritative rebase over pending outbox

Add a case named
`authoritative rebase notifies and publishes merged pending intent`.

The case should queue an optimistic edit, subscribe, and then apply an
authoritative update that causes the queued mutation to be replanned. It should
verify that one notification describes the logical difference and that the
successor snapshot contains the authoritative base with the still applicable
optimistic intent overlaid on it. `Database.inspect_sync` should also prove that
the pending submission remains queued with its replanned state.

This case exercises an authoritative database update and an outbox projection
update in the same publication and is therefore required in addition to the two
direct publication cases. Its assertions must stay at the stable public
projection and sync-view boundary rather than inspect private planner details.

All three cases must use `Database.get_blocks` plus a `Children` structure read
as their baseline successor pull. A case should add a complete `Page_tree` read
only when its fixture introduces a multi-level subtree whose recursive nesting
or ordering is not established by the direct children result. The proposed
single-block and single-level child fixtures do not require `Page_tree`.

## Decision

Adopt all three closed-loop cases. The user resolved the testing-scope questions
on 2026-09-04:

- require the independent optimistic outbox case A and authoritative case B;
- also require combined authoritative-rebase case C so one publication proves
  the merged authoritative and pending-outbox contract; and
- use `get_blocks` plus `Children` as the normal successor pull, adding
  `Page_tree` only when a case introduces a multi-level subtree.

## Alternatives considered

### Extend only the existing listener assertions

Acquire a new snapshot and add reads directly to the existing local-commit and
authoritative-listener cases.

This minimizes case count, but each existing test would own two distinct failure
stories. A failure would be less clear about whether notification construction
or successor publication broke. Dedicated closed-loop cases make the consumer
contract explicit while leaving focused listener diagnostics intact.

### Rely on separate listener and projection tests

Keep the current suite unchanged because each individual operation already has
notification and read coverage elsewhere.

This does not prove that a notification's `after_revision` names the snapshot
from which the affected data can actually be read. It leaves the exact
cross-boundary regression untested.

### Read from inside the listener callback

Have the callback immediately call `Database.current_snapshot` and public read
functions.

This mixes delivery reentrancy with publication correctness and may turn a
closed-loop data test into an accidental callback-locking test. Resolving a
promise and reading on the test fiber isolates the intended contract.

### Add the cases to `test_overlay_sync.ml`

The transition fixtures already exist there, but the listener contract belongs
to the merged logical change suite. Keeping the closed-loop cases in
`test_overlay_changes.ml` also avoids duplicating listener setup across suites.

## Acceptance criteria

- At least one outbox-driven transition is covered from predecessor snapshot,
  through an adjacent `Exact` listener notification, to correct successor
  public reads.
- At least one authoritative transition is covered through the same closed
  loop.
- One authoritative rebase over pending outbox intent is covered from the
  authoritative transition, through one adjacent listener notification, to the
  merged successor projection and durable queued submission state.
- Each case asserts the relationship among predecessor projection revision,
  notification `before_revision` and `after_revision`, transition result, and
  successor snapshot version.
- Each case validates notification interests and the corresponding block and
  structure reads, rather than checking revision advancement alone.
- Each case uses `get_blocks` and a `Children` request for its baseline pull.
  `Page_tree` is required only for a fixture that introduces a multi-level
  subtree.
- Outbox-driven coverage verifies the durable submission state with
  `Database.inspect_sync`.
- Authoritative coverage verifies the durable checkpoint with
  `Database.inspect_sync`.
- Tests use only `Logseq_overlay_db.Database` and `Logseq_overlay_db.Types`
  public APIs and the existing `Test_support` fixture vocabulary.
- Subscriptions and snapshots are released on successful and failing paths.
- The new tests fail when the successor read assertions are deliberately
  inverted, then pass without requiring production behavior changes.
- `dune exec logseq_overlay_db/test/test_overlay_changes.exe` passes.
- `dune runtest logseq_overlay_db/test` passes.
- `dune build @fmt` and `spec-dev-tool check --all` pass.

## Risks

- Reusing a large authoritative Transit fixture can obscure the core
  notification-to-read contract. The test should extract a shared fixture only
  if doing so makes both the existing and new cases easier to read.
- A combined rebase case may fail for legitimate rebase-policy changes even
  when basic publication remains correct. Its assertions should describe the
  stable public overlay contract rather than private planning details.
- Waiting for a promise without deterministic cleanup can hang the suite after
  a missed notification. The implementation should follow the existing Eio
  listener-test pattern and keep the transition and await sequence bounded by
  deterministic test fixtures.
- Asserting only point reads would miss incorrect structure invalidation;
  asserting every projected field would make the test brittle. The selected
  fields should prove identity, content, parentage, and order without copying
  the complete projection suite.

## Consequences

The merged logical change suite will contain three explicit consumer-loop
contracts rather than relying on separately passing listener, mutation, and
sync suites. A regression can be localized to optimistic publication,
authoritative publication, or authoritative rebase over pending intent.

The cases add direct-children projection assertions but no unconditional full
page-tree projection checks. Recursive page-tree coverage remains owned by
fixtures that actually exercise multiple levels, keeping these tests focused on
the relationship among transition commit, notification revision, and successor
snapshot.

## Questions

None. The user confirmed that cases A, B, and C are all required, that
`get_blocks` plus `Children` is the baseline pull, and that `Page_tree` is
required only for a multi-level subtree fixture on 2026-09-04.
