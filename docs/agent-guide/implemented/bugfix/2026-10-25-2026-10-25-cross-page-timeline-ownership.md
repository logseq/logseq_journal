# Cross Page Timeline Ownership

## Problem

A normal Web cross-day move followed by an edit produced duplicate root identity P002 and a blank native Timeline. The actual native JSON decode succeeds but Snapshot rejects duplicate row keys. An isolated normal append move with real Worker FIFO reproduces65 roots becoming66 rows/65 UUIDs after all143 requests drain. Point projection combines a returned new page ID with a captured old date/parent context; in-place row replacement breaks page grouping and a page-local contiguous splice retains an old duplicate suffix.

## Decision

Resolve moved point reads against their returned page, using cached page metadata or the existing get-page command. Reject mismatched projection contexts and retire superseded point/context completions. Keep page and Detail ownership caches consistent. A resync also retires every pre-resync point observation before starting current-interest reads, including saved block records waiting for page metadata; only observations started after that boundary may publish.

At the Timeline owner, move or remove a point-updated root when its page, parent, date or order changes; insert only inside an already loaded target range. An authoritative page replacement removes all old rows belonging to that page and old occurrences of incoming UUIDs globally, updates affected date counts and reinserts in date/sibling order. Preserve unread continuations and surviving UUID anchors. No Swift-only dedup, Worker API, protected spec or Dune changes.

## Alternatives considered

### Native duplicate suppression

Silently dropping repeated row keys would hide wrong page/date/parent ownership and leave stale data. Retaining the last valid native snapshot is separate resilience work; it is not the requested semantic fix.

## Acceptance criteria

- Minimal public Runtime and Timeline owner regressions fail before the correction, including valid source/target/point completion orders, loaded prefix/suffix, root/child transitions, unknown destination pages, stale point/context responses, counts, continuations and anchors.
- Recompile the existing default30 real Worker FIFO trace against final sources, preserving normal authoritative transaction shape and limits. Every published Timeline has unique root keys and consistent page/date/parent; normal pagination eventually yields the exact root set. The corrected trace has64/64 visible after natural drain, plus the moved root outside the target prefix; one normal continuation restores65/65. This is legitimate deferred loading, not a claim of65 visible before that continuation.
- Push- and pull-triggered resync retire both unfinished point reads and saved point-context reads after fresh roots publish, whether a root remains on its destination or moves back. New post-resync points still publish; graph reset remains a retirement boundary. Eight resync combinations fail before correction and pass afterward; two reset controls pass throughout.
- Appropriate final full regression and exact-head CI pass; update the existing formal PR117, without merge/release.
- Hand off final source/provenance to the existing native acceptance owner for19 real-user scenarios. Pure tests do not count as all19 acceptance.

## Consequences

- A moved root outside a loaded target prefix can disappear from its old page until normal target pagination reaches it. Do not force an unrequested subtree into Timeline to keep it visible.
- Valid concurrent responses can temporarily expose only one side of a move. Each published state must remain internally consistent and globally unique.
- Native/Web completion history of the original failure was not recorded; the isolated FIFO mechanism is sufficient reproduction, not a reconstruction of that history.

## Questions

- None. The user approved the suggested ownership/page-replacement fix and PR117 update. Native fixture/GUI and19-scenario execution remain coordinated by the original acceptance owner; this work does not modify the preserved fault graph/process.
