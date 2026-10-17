# Remove Discarded Commit Callbacks

## Problem

The three commit paths in `logseq_overlay_db/lib/database.ml` collect active
subscription callbacks under the database mutex, return that list through every
success/error branch, and immediately discard it with `ignore callbacks`.
The list is neither invoked nor retained. This repeats a subscription scan and
obscures the real notification owner.

The reviewed baseline is main `fc27cfd62e7fede81185c7ec0bc8807fca797b52`.
`commit_local`, `apply_outbox_transition`, and `commit_authoritative_candidate`
all call `serialize_commit`. That function reserves dispatcher capacity before
the mutation, enqueues the committed change and awaits queue delivery. The
dispatcher selects active subscriptions and publishes to their streams;
`activate_subscription` owns callback execution and its lifecycle fences.

## Proposal

Remove only the discarded callback collections and the unused component of each
private return tuple. Keep the existing `(change, outcome)` results, persistence,
locks, dispatcher reservations, stream delivery and callback lifecycle unchanged.
No public interface, protected spec, Dune file, dependency or platform bridge
changes are required. The user authorized implementing both audited
simplifications, testing and opening a PR on 2026-10-17
(Sentinel_b66872b73d108191964dce936fc35406).

## Decision

Adopt the proposal as authorized. The implementation is confined to the private
overlay implementation; the existing behavioral contracts remain unchanged.

## Alternatives considered

### Keep a callback snapshot at commit time

A snapshot could support a different notification contract, but no current
consumer receives this list. Wiring it into delivery would change the existing
dispatcher and unlisten semantics. The existing stream owner remains authoritative.

## Acceptance criteria

- All three commit paths return the same success/error outcomes and change events.
- No-change/transport-only commits remain silent; concurrent commits publish in
  revision order and reserve capacity before committing.
- Callback exceptions remain isolated. Self-unlisten, external unlisten and close
  retain their current in-flight callback behavior.
- Existing `test_overlay_changes` and `test_overlay_concurrency` pass before and
  after the deletion; final full build and tests pass.
- No new behavior is introduced, so existing owner tests are the regression
  baseline; do not add tests that assert source spelling or unused tuple shapes.

## Risks

- Mechanical tuple edits must not change a branch result or the real dispatcher.
  These are private implementation tuples, not a public contract cutover.

## Consequences

Commit paths no longer allocate discarded subscriber lists or carry an unused
private tuple component. Dispatcher capacity, notification streams and callback
lifecycle remain the sole delivery mechanism. No interface or persistence
format changes are introduced.

## Questions

None. The implementation and PR are explicitly authorized; no new product or
interface decision is needed.
