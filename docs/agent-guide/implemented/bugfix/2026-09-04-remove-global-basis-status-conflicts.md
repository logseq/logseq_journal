# Remove Global Basis Status Conflicts

## Problem

Changing a Timeline block's task status can fail with the snackbar message
`Status changed elsewhere. Try again.` even when that block did not change.
The failure is a local false conflict rather than a conflict reported by Overlay
DB or the Worker mutation precondition.

`Journal_graph_projection` currently converts the runtime-wide `basis` counter
to an integer and stores it as `Journal_model.revision` on every projected
block. Application copies that integer into `Set_task_state.expected_revision`.
Before emitting `V2_set_task_status` or `V2_clear_task_status`,
`Journal_graph_runtime` compares the copied integer with its current global
`t.basis`. A mismatch triggers a page-tree refresh and returns
`Update_conflict`, which Application unconditionally presents as a concurrent
status change.

The global counter advances whenever the runtime observes a different Overlay
DB `projection_revision`. An unrelated block mutation can therefore advance
`t.basis` while the selected block and its target-local revision remain
unchanged. The next status selection for that block is rejected before its
actual target-local Worker precondition is attempted. The conflict refresh
usually stamps the latest global counter onto the block, so an immediate retry
may succeed until another unrelated projection change advances the counter.

This behavior contradicts the Overlay DB concurrency contract. A snapshot has
one global `projection_revision` for ordering logical projection events, while
blocks, pages, and structure scopes have independent opaque state revisions for
equality preconditions. An unrelated graph transaction must not invalidate a
target-local mutation. `Set_task_status` and `Clear_task_status` require only
the caller-observed target block revision.

The V2 runtime already retains the opaque block revision returned by Worker
reads and places it in the mutation precondition. However, it currently chooses
the latest token from its private `block_revisions` table instead of carrying
the caller-observed token through the Application request. The obsolete integer
fields also remain on update, delete, and child-create requests even though the
runtime does not consult them. Removing only the status comparison would fix
the visible false conflict but leave two misleading revision models and would
not prove that a mutation is guarded by the exact state the user acted on.

`t.basis` has no remaining Overlay DB database-basis meaning. It is a local
counter derived from changes to the opaque global `projection_revision`. It is
also copied into runtime responses for a `minimum_basis` feed fence, but every
current producer initializes `minimum_basis` to `None`, so that comparison does
not reject any response. Request generation, graph generation, projection
change delivery, and target-local revision preconditions already own the
corresponding ordering and concurrency responsibilities.

## Proposal

Replace basis-derived object revisions with the exact opaque target-local
revision returned by Worker V2 reads.

Carry each block revision alongside the projected block through
`Journal_graph_projection` and Application state. Every mutation request that
claims to act on an observed block must carry that opaque revision:

- source update carries the observed target block revision;
- task-status set or clear carries the observed target block revision;
- subtree delete carries the observed root revision and continues to use the
  relevant retained structure-scope revision;
- child creation carries the observed parent revision and continues to use the
  destination structure-scope revision.

`Journal_graph_runtime` must build the Worker V2 precondition from the revision
in the admitted Application request. It may retain revision tables for read
reconciliation and registered-interest hydration, but it must not silently
replace a caller-observed mutation precondition with a newer private value.
Worker and Overlay DB remain the authorities that decide whether the opaque
target-local precondition matches.

Delete the status-specific `expected_revision <> t.basis` branch. A genuine
Worker conflict must retain the existing authoritative refresh behavior:
refresh the affected block or page fragment, clear the pending mutation, keep
the stored authoritative status, and show the existing accessible retry
message. An unrelated projection event must neither emit `Update_conflict` nor
prevent the status mutation from reaching Worker.

Remove the obsolete global integer revision chain in the same cutover rather
than retaining compatibility fields or aliases:

- remove `t.basis` and the integer conversion in `Journal_graph_projection`;
- remove `Journal_model.revision` and its integer storage;
- replace integer `expected_revision` and `expected_parent_revision` request
  fields with opaque target-local revision values;
- remove basis-derived `parent_revision` response plumbing and update a
  refreshed parent from its authoritative projected value and revision;
- remove `Journal_graph_runtime.response.basis`, `feed_refresh.minimum_basis`,
  and the dormant basis comparison unless investigation finds a reachable
  non-`None` producer that cannot be represented by the existing request and
  graph-generation fences.

Keep Overlay DB `generation`, global `projection_revision`, listener change
ordering, change-window cursors, request generations, graph generations, and
block/page/scope revisions. This proposal removes only the App-owned numeric
facsimile and its use as object identity; it does not weaken Overlay DB snapshot
or mutation concurrency semantics.

Implementation must follow test-driven development. Add the failing regression
coverage before changing production code, observe the false conflict, then make
the minimum coherent target-local revision cutover that passes the new and
existing contracts. Do not modify OCaml files under `spec/` or any Dune file
unless the required public `.mli` revision type is unclear; if an existing
`.mli` cannot express the required opaque revision, stop and report the spec
issue rather than bypassing it.

## Decision

Perform the complete target-local revision cutover and delete the obsolete
numeric basis chain. Do not limit the implementation to removing the
status-specific guard. The user confirmed this scope on 2026-09-04 after
reviewing the distinction between Overlay DB snapshot `projection_revision`,
target-local block revisions, and the App runtime's synthetic `t.basis`.

Preserve global projection ordering and selective listen/pull hydration while
making every supported mutation use the exact opaque revision observed with its
target. Remove dead integer revision fields, dormant basis response fencing,
and runtime-side substitution rather than retaining compatibility paths.

## Alternatives considered

### Remove only the status global-basis comparison

Delete the guard in `Journal_graph_runtime.Set_task_state` and continue using
the runtime's latest retained block revision. This is the smallest symptom fix,
and the Worker would still reject a real stale target. It is not recommended
because the request's integer `expected_revision` would become dead data, the
same obsolete fields would remain on other mutations, and the precondition
would no longer explicitly represent the revision observed by the caller.

### Refresh the complete Timeline after every projection event

Reproject every visible block so all basis-derived integers equal the newest
global counter. This would reduce the false-conflict window but retain the
incorrect global concurrency model, perform unrelated reads and UI updates,
and still race with another projection event. It conflicts with the Worker's
UUID- and interest-local hydration design.

### Automatically retry after the false conflict refresh

Keep the global comparison, refresh the block, and submit the status mutation
automatically. This hides the first error but changes an explicit user retry
into an automatic write and can apply an intent after a genuine target change.
The invalid precondition should be removed rather than retried around.

### Use global `projection_revision` directly as every block revision

Replace the integer counter with the opaque global revision but keep the same
comparison. This preserves the false-conflict behavior because any unrelated
logical projection change still changes the global token. Global ordering and
target equality must remain separate.

## Acceptance criteria

- Given two visible blocks, committing a mutation to one block and advancing
  global `projection_revision` does not reject a subsequent status mutation for
  the unchanged block.
- The unchanged block's status mutation reaches Worker with exactly its
  caller-observed opaque block revision as the sole block precondition.
- A real target-block revision mismatch is rejected by Worker or Overlay DB,
  refreshes the affected authoritative fragment, clears the pending status
  mutation, and shows the existing accessible retry message.
- Status success still reconciles through an authoritative projection and does
  not optimistically overwrite the row.
- Source update, task-status change, subtree delete, and child creation each use
  the exact caller-observed target or parent block revision. Delete and child
  creation retain their required target-local structure-scope preconditions.
- Global `projection_revision` changes continue to drive ordered Worker change
  delivery and selective hydration of registered block, page, and scope
  interests.
- Transport-only changes and unrelated logical projection changes do not
  invalidate an otherwise valid target-local mutation.
- `t.basis`, basis-derived `Journal_model.revision`, integer expected-revision
  fields, basis-derived parent revision plumbing, `response.basis`, and dormant
  `minimum_basis` state are absent unless a concrete reachable ordering use is
  documented and represented with the correct global revision type.
- No compatibility field, alias, fallback global comparison, or silent
  substitution of a newer runtime revision remains.
- Regression tests demonstrate RED before the implementation and GREEN after
  it for Timeline status, Detail status, source update, delete, child creation,
  genuine conflicts, unrelated projection events, and selective listen/pull
  hydration.
- Focused tests, the complete OCaml test suite, formatting, build, source
  boundaries, and `spec-dev-tool check --all` pass.
- The implementation complies with `docs/ux-guidelines.md`, modifies no Dune
  file, and modifies no OCaml file under `spec/` unless the user separately and
  explicitly authorizes the required `.mli` change.

## Risks

- The current projection helpers discard Worker member revisions when reducing
  protocol records to graph blocks. Preserving the opaque token through every
  feed, detail, point-read, and mutation-refresh path touches several shared
  projection types and must not pair a token with the wrong block.
- Using the caller-observed token can expose real conflicts that were previously
  hidden when the runtime silently substituted a newer retained token. Those
  conflicts are correct, but source editing, status selection, delete, and
  child creation must all terminate their pending UI state consistently.
- Removing `response.basis` is safe only if its dormant `minimum_basis` path has
  no reachable non-`None` producer. The implementation must prove this with
  source-boundary coverage before deletion; if a real freshness requirement is
  found, it must use opaque global `projection_revision` or an existing request
  generation rather than recreate a numeric database basis.
- Opaque revisions must remain equality tokens. Application must not order,
  increment, parse, display, or synthesize them.
- This bugfix intentionally gives up the legacy ability to compare every block
  against one numeric graph-wide version. That behavior is incompatible with
  Overlay DB target-local concurrency and must not be retained as a fallback.

## Consequences

Application-visible blocks now retain opaque Worker revisions as equality
tokens. Source edits, task-status changes, subtree deletion, and child creation
send the exact revision observed by the user, while structure-changing
mutations continue to include their independently retained scope revision.

The App runtime no longer maintains a synthetic numeric basis or stamps every
projected block with one graph-wide counter. Global projection revisions remain
inside Worker change ordering and hydration, while graph generation and request
generation continue to fence lifecycle and presentation work. Genuine target
conflicts still refresh authoritative state and require the existing explicit
retry; unrelated graph changes no longer create local false conflicts.

## Questions

- None.
