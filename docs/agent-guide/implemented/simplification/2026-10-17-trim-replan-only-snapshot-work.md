# Trim Replan Only Snapshot Work

## Problem

`replan_queued_ordinary` in `logseq_overlay_db/lib/database.ml` reverses its
accumulated outbox for every queued ordinary mutation and builds a children
effect index whose per-parent lists append each record. Neither value is read
by this temporary snapshot's consumers, adding avoidable cumulative work.

At main `fc27cfd62e7fede81185c7ec0bc8807fca797b52`, both authoritative commit and
stale-rejection settlement enter this private function. The temporary snapshot
only reaches `logical_snapshot_satisfies_mutation`, `invalid_replan_dependency`
and `ordinary_effect_footprint`. Their transitive block, page, asset-descriptor,
asset-version and tombstone readers consume the authoritative root and block/page
effect maps. They do not enter journal enumeration, child enumeration or public
snapshot dispatch. The normal snapshot outbox and children indexes have real
consumers elsewhere and remain required.

## Proposal

Remove this function's children-index construction and threaded accumulator.
Leave `outbox` and `children_effects` uncaptured (`None`) in this private
temporary snapshot, so an unexpected future structural read fails explicitly.
Preserve the actual final outbox accumulator, stable sequence order, block/page
effect buckets, active dependency shadows, tombstones, asset checks, normalized
transactions and result classifications. Do not redesign the shared snapshot or
modify its public interface, protected spec, Dune files or dependencies.

The user authorized implementing both audited simplifications, testing and
opening a PR on 2026-10-17
(Sentinel_b66872b73d108191964dce936fc35406).

## Decision

Adopt the proposal as authorized. The implementation is confined to the private
overlay implementation; the existing behavioral contracts remain unchanged.

## Alternatives considered

### Generalize a separate replan snapshot API

A new representation would prevent future structural reads but require broad
reader/interface changes. The current snapshot remains private and the complete
local call chain is small enough to verify; a targeted deletion removes work
without moving complexity into another API.

## Acceptance criteria

- Existing ordinary rebase, no-change, transitive dependency blocking and stale
  settlement tests pass before and after the deletion.
- Asset-reference replan, local asset descriptors, tombstones and chronological
  block/page effect replay retain their current behavior.
- General journal, children and page-tree reads retain their real indexes.
- Existing overlay sync/asset/read/mutation cases and final full build/tests pass.
- No public interfaces or new persistence/scheduling mechanisms are introduced.
  Add behavior coverage only if the existing cases leave a demonstrated gap.

## Risks

- A future call to a structural reader from this temporary path would need its
  required index. Current call-chain review must include nested asset/tombstone
  reads; the general snapshot producers must not be changed.

## Consequences

Ordinary replan no longer builds a children-effect map or repeatedly reverses
its retained prefix for an unread temporary snapshot field. Real block/page
effect buckets and the final retained record order remain authoritative. General
journal and structure snapshot producers retain their required roots.

## Questions

None. The implementation and PR are explicitly authorized; no new product or
interface decision is needed.
