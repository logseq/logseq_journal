# Recover Stale Timeline Pagination

## Problem

Scrolling down Timeline can produce `loadDayPageTree` /
`unsupportedSemantics` / `The page-tree query failed.` The day continuation and
older-day continuation then remain on Loading, preventing further pagination.

The failure has three connected causes:

1. Overlay structure cursors contain a global projection revision and an offset.
   `Database.current_snapshot` captures the current projection for each worker
   read, and the worker releases the snapshot after that read. Timeline retains
   the returned cursor, not the snapshot lease. A logical change can therefore
   invalidate a retained continuation before the next page request.
2. The worker's page-tree branch discards the typed read error and returns
   `invalidRequest`. `Journal_graph_runtime.failure_output` then reconstructs it
   as `Unsupported_semantics`, losing the distinction between stale pagination
   and an unrelated query failure.
3. `Day_page_tree` failure becomes a generic `Rejected` response. Application
   records that error and calls `fail_active_mutation`, which does not complete
   the timeline read. `Journal_timeline_state.next_request` returns no request
   while its pending slot remains occupied.

Listen delivery does not eliminate the first cause. `hydration_for_changes`
refreshes affected blocks, pages, and structures. A block-only update replaces
content without replacing the continuation. A page-tree refresh replaces that
page's continuation, but other pages can retain cursors from an older global
projection. Even a relevant refresh can race with an in-flight continuation.
Timeline does not own a separately editable projection revision: it stores the
opaque protocol cursor. Rewriting its encoded revision would incorrectly reuse
an old offset on a different result set.

### Evidence

On 2026-09-06 a disposable database reproduction used compiled public interfaces:

- Read a real page-tree continuation; verify continuation on the unchanged
  snapshot succeeds.
- Create an unrelated journal with its observed missing-page precondition.
- Read a new snapshot with the old cursor. The database returns
  `Invalid_read_request "invalid or stale structure cursor"`.
- Repeat through the real worker reducer, effect runner, and graph runtime. The
  worker returns `invalidRequest`; runtime emits the exact screenshot operation,
  code, and message, with zero recovery requests.
- A fresh page-tree query without a cursor succeeds.

The temporary evidence is in `/tmp/timeline-investigation/result.log` and the
public-interface probe in `/tmp/timeline-investigation/probe.ml`. These temporary
files are investigation artifacts, not permanent regression tests or build
inputs. The original process sent stdout/stderr to `/dev/null`; the precise
mutation or sync transaction preceding the user's request cannot be recovered
from that output. Application's missing failure cleanup was established by source
inspection, not claimed as an end-to-end UI reproduction.

## Proposal

The user selected recovery on a fresh projection: terminate the stale pagination
attempt, reconstruct the required page range, and publish matching rows and a new
continuation together. Retain projection-bound cursor validation and the existing
short-lived snapshot leases. The user approved transition to proposed on
2026-09-06. Implementation and regression validation are recorded in the validation report below.

### Preserve a machine-readable stale-cursor result

Distinguish a well-formed cursor whose projection no longer matches from malformed
cursors, invalid bounds, read limits, closed sessions, and storage failures.
Propagate that distinction through the overlay read result, worker protocol, and
graph runtime. Preserve other failures' original categories and diagnostic
messages. Do not classify recovery by matching an English error message, decode
opaque cursors in Application, or convert every failure into unsupported semantics.

The existing public overlay `read_error` exposes only `Invalid_read_request of
string` for cursor rejection. The preferred contract change is a dedicated
`Stale_read_cursor` constructor in `logseq_overlay_db/spec/types.mli`, with
corresponding documentation in `logseq_overlay_db/spec/database.mli` distinguishing
stale and malformed continuations. Update the implementation type and worker
error/protocol representation consistently; use one current representation,
without compatibility decoders or fallback classification paths.

On 2026-09-06, the user explicitly authorized the spec changes necessary for this
fix. This includes the overlay `.mli` changes above and any other spec `.mli`
changes required to carry the selected stale-cursor recovery contract. The
repository's explicit-authorization requirement is satisfied for that scope;
implementation must not request the same authorization again. This does not
authorize changes to OCaml implementation files under `spec/`, dune files, or
bonsai_flutter OCaml files.

### Give each day request a complete lifecycle

Extend the existing timeline request owner with explicit completion paths for
normal continuation, recovery, and terminal failure. A completion must identify
the day and request generation; graph/session ownership must also remain valid.
A late completion from an older request must not clear, append to, or replace the
state of a newer request. Preserve these identities through runtime responses
instead of discarding them into generic `Rejected`.

A stale continuation completes the old attempt and starts a distinct recovery
attempt with fresh ownership. Other read failures complete the matching request
and expose a retryable day error without being routed through capture, status, or
delete failure handling. A failed day must not permanently occupy the global
pending slot or prevent eligible older-day requests from progressing.

### Rebuild and replace a coherent range

Recovery starts at `cursor = None` on the current projection. Keep the existing
visible rows while collecting the replacement in bounded staging state. Read
through the range needed to preserve the visible anchor and satisfy the original
pagination demand, subject to existing retained-row, request-size, and cursor
bounds. Do not fetch an entire journal without a work bound.

Use only cursors actually returned by the recovery reads. If a later read becomes
stale, discard that staging attempt; never combine chunks known to belong to
different projections. Publish the replacement rows and their continuation as one
state transition after the required range has been assembled. Successfully
recovered data must replace the affected day range, not append a fresh first page
to the old tail. Remove rows absent from the rebuilt range and preserve unique
block identity and sibling order. Leave other days intact.

Keep the visible block identity in the logical retained window and prefer its
nearest surviving neighbor when replacement removes it. Preserve surviving
expansion state and reload child previews from their current parent rather than
retaining obsolete previews. Reaching the work budget before reconstructing the
required range remains a recoverable failure.

On 2026-09-06, implementation verified that the installed public viewport API
reports visible indexes only and does not expose a block-key/pixel-offset restore
operation. The native varied-extent implementation corrects offsets by index.
The user explicitly selected completing bounded recovery while accepting that the
viewport position may shift. Exact pixel-offset restoration and its deleted-anchor
fallback are therefore outside the agreed implementation scope; no framework
change or private renderer payload is required.

The existing `replace_timeline_entry_page` is not sufficient on its own: it does
not complete pending recovery, validate a request generation, or guarantee that
a rebuilt range covers the visible anchor. Integrate those responsibilities with
the request lifecycle instead of adding a second independent recovery owner.

### Bound recovery and reconcile concurrent updates

For each user/viewport pagination demand, allow one automatic fresh rebuild after
stale rejection. If that rebuild becomes stale again, exceeds its work budget, or
fails for another reason, discard its staging state and end Loading. Present a
local Retry action using an appropriate built-in Flutter component. Retry creates
a new request generation and fresh recovery budget. Further visible-range events
alone must not repeatedly retry the same terminal failure.

Listen-driven page replacements and mutation refreshes must participate in the
same request ownership rules. A replacement that supersedes an in-flight request
must invalidate that request before publishing; its late response cannot append
old data. Changes affecting a staged recovery must not be overwritten by that
staging result. Preserve listener arrival ordering with recovery completions and
reconcile or supersede staging through the owner rather than independently
mutating the visible page.

This fix does not require eagerly reloading every retained day on every global
projection change. Lazy stale detection must remain correct even after a
block-only push, an unrelated-page update, or a delayed listen delivery. A later
optimization that proactively invalidates continuations must use the same
recovery lifecycle, and cannot replace stale-response handling.

The UI must continue to comply with `docs/ux-guidelines.md`: use built-in Flutter
components, retain the divider limit, and preserve launch behavior. User-facing
retry text should describe the loading problem without exposing cursor or
projection implementation details.

### Production ownership and verification boundary

Classify each defect before adding a regression testcase, following
[the pure reducer testing decision](../../implemented/testing/2026-09-06-restrict-pure-reducer-reproducible-bugs-to-pure-testcases.md).

- Pagination pending, recovery attempts, terminal failure, publication, and stale
  completion rejection belong to the existing timeline request state owner.
  First reproduce through its public events/completions, state, and effects.
  For behavior reproducible there, add only pure reducer regressions, including
  controls that distinguish valid and obsolete request completions.
- Cursor validation belongs to `Database.get_structure` and its snapshot state.
  Worker Core emits `Execute_request` and receives an external completion; it
  does not implement cursor validation. Injecting a stale result into Core does
  not reproduce the database boundary. Reuse existing cursor tests; if the new
  typed result needs new coverage, use only the public Database boundary with a
  real returned cursor and a real logical commit.
- Error conversion belongs to the worker/runtime conversion paths. Attempt a
  public pure boundary reproduction of each conversion defect first. If none
  exists, document the missing ownership boundary and test only the narrowest
  public layer executing that conversion. Do not duplicate the whole scrolling
  scenario at runner, persistence, integration, or UI layers.
- The current Application state reducer is not exposed as a general public
  reducer interface. Do not bypass `application.mli`, use `#mod_use`, copy its
  implementation into tests, or move production ownership solely to label a test
  pure. Establish the narrowest legitimate boundary before placing dispatch
  regressions.

Use deterministic event orderings for normal continuation, stale continuation,
recovery success, repeated staleness, a non-stale failure, graph switching,
listen replacement during recovery, deleted anchors, and late completions.
Use intended-behavior assertions that fail before the fix. Keep all existing
regressions; running them or manually validating scrolling is distinct from
adding duplicate regression coverage. This proposal adds no tests; implementation
must establish and validate the regression boundaries described above.

## Decision

The timeline owner now handles day-specific failures, one bounded fresh rebuild,
atomic replacement, terminal Retry, and generation fencing. Recovery permits up
to 16 reads of the existing 64-item request size and at most 512 staged top-level
entries. A failed day does not block visible older-day demand. Page replacements,
content updates, deletes, and captures supersede affected staging. Expansion is
retained for surviving parents, with current child previews requested afresh.

`Stale_read_cursor` is carried through the overlay type, worker error codec, and
runtime day-failure response. Malformed cursors remain invalid requests; read
limits, closed snapshots, and storage errors retain their own worker categories.
Day failures never enter mutation-failure dispatch.

See [implementation validation](../../../test-reports/2026-09-06-proposed-docs-validation.md)
for reproduction ownership, automated coverage, and manual database verification.

## Alternatives considered

### Accept old offsets or rewrite cursor revisions

Rejected. An insertion or deletion before the offset can produce skipped or
duplicated items. The projection-bound validation policy is intentional.

### Clear the cursor and reuse the append completion

Rejected. This appends the first page to retained rows and preserves stale or
duplicate content. Recovery requires replacement semantics.

### Keep a snapshot lease for the lifetime of timeline pagination

Not selected. This changes resource ownership and requires an explicit switch
between old snapshot content and live listener updates. Keeping the lease alone
does not define that switch or satisfy the selected live recovery behavior.

### Reload the entire timeline for every listen push

Not selected. Frequent edits would repeatedly reset unrelated pagination and
increase query work. It also leaves a race between pushes and read completions.

### Clear pending and show an error without recovery

Insufficient. It removes the permanent Loading state but makes routine logical
updates interrupt scrolling. One bounded automatic rebuild handles that expected
invalidation while retaining a terminal Retry state.

## Acceptance criteria

- A real cursor invalidated by a logical commit produces a distinct stale-cursor
  result through the worker/runtime boundary, without English-message matching.
- Normal valid continuation still appends once in the correct order.
- A stale day continuation releases its original request and starts at most one
  automatic fresh rebuild for that demand.
- Recovery publishes a coherent replacement and matching continuation together,
  with no duplicate IDs, missing requested range, or obsolete rows retained merely
  because they existed before recovery.
- Logical anchor selection prefers surviving nearby blocks within bounded work.
  Exact viewport position may shift, as explicitly accepted by the user.
- Repeated staleness, work-budget exhaustion, and other failures end Loading,
  offer explicit Retry, and leave the pending slot available for further work.
- Old responses after recovery, listen replacement, graph switch, or explicit
  retry cannot alter the newer operation or clear its pending state.
- Localized listen refreshes do not overwrite or get overwritten by obsolete
  recovery staging. Correctness does not depend on prompt listen delivery.
- Regression placement follows production ownership and the exclusive pure
  reducer rule. No spec implementation is bypassed and no existing test removed.
- Spec `.mli` changes stay within the necessary recovery contract authorized by
  the user; no dune or bonsai_flutter OCaml file is changed.

## Consequences

- Reconstructing a deeply paginated day can be expensive. Work and retained-memory
  bounds must be explicit, and exhaustion must remain visible and retryable.
- Global projection binding can invalidate a rebuild during unrelated activity.
  The bounded retry policy trades immediate progress for avoiding an unbounded
  loop; it does not promise progress while the graph changes continuously.
- Concurrent listener and read completions can resurrect deleted rows or leave a
  request orphaned unless they share operation ownership and ordering rules.
- Anchors, expanded children, and pending optimistic mutations make replacement
  more involved than replacing a cursor. Tests must exercise those actual owners
  without broadening this fix into an unrelated rendering redesign.
- The current overlay read-error spec lacks the required stale constructor.
  Implementing message-based classification would hide that contract deficiency.

## Questions

None. The user explicitly selected the bounded stale-cursor recovery approach,
authorized necessary spec changes, and approved transition to proposed on
2026-09-06. The one-rebuild budget and deleted-anchor behavior above are the
implementation defaults. The spec-edit authorization prerequisite is resolved.
