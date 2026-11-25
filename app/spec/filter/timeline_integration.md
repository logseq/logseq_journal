# A1 Timeline filter: integration and API review

Design only. `timeline_filter.mli` owns settings values and the sheet draft.
The existing graph feed plan owns selection, pagination, freshness and assembly.

## Per-graph preferences

The App host saves the last successfully applied criteria in local
`UserDefaults.standard`, keyed by the stable graph UUID (not its display name
or transient graph generation). Use a versioned value containing tag UUIDs,
status UUIDs and the relative time choice, including preset vs. custom. Do not
save draft edits, search text, resolved dates, cursors or results. This is a
local UI preference; it does not enter Worker, Overlay DB or graph sync.

Restore the active graph's criteria before issuing its first Timeline query,
including after a cold start. Missing or invalid preferences use `Any` without
loading settings from another graph. Keep the sheet closed on restore and
re-resolve relative time against the current local calendar. If preferences are
loaded asynchronously, fence completion by the active graph/request generation.
Switching to Favorites and back does not reset criteria. Reset alone edits only
the draft; after Apply, canonical `Any` removes only this graph's preference
entry. Cancel or rejected Apply leaves the persisted value untouched.

## One Timeline path

- Build one feed request from the applied settings, including `all` for the
  current Timeline. `all` is the identity restriction, not another loader or
  renderer. Keep the existing date ordering, root ordering, `timeline_entry`
  projection, child previews, and row interactions.
- Resolve relative time from the App's local calendar into inclusive journal
  page day bounds. Recent N days start at today minus N−1 calendar days;
  recent N weeks mean 7×N days. `Any time` leaves the existing bounds alone.
  Re-resolve on a local-day/time-zone change. Range overflow is a query/preview
  error, not an empty result. Keep that arithmetic out of the settings module.
- Reuse `Timeline_read(Dates)` with those date bounds. For each existing Roots
  packet, apply the predicate to the **same visible depth-0 candidates** before
  enqueuing `Preview_children`; then use the existing projection and assembly.
  Match the root's `Graph.block.tags` UUIDs and persisted `block_record.task_status`
  from that packet. No string matching, descendants, or extra per-root reads.
  The predicate is `in_range && (no_tag_or_status_selected || tag_hit || status_hit)`.
  An empty selection group cannot satisfy the OR when the other is selected.
- Keep raw scan progress independent of emitted rows. Advance from the packet's
  continuation, never from the last matching row. The feed planner must continue
  in bounded, cancellable turns when there are no rows to trigger scrolling;
  respect request, structural and encoded-byte limits. Do not publish a date
  heading with no matches. Distinguish searching, failed and exhausted.
  Apply, date-bound changes and graph switches fence stale results; reset plus
  Apply sends `all` through this same path. The normal bottom controls stay.

## Public API impact

| Layer | Proposal | Reason |
| --- | --- | --- |
| App feed / Timeline cursor | Thread one query value through initial feed, continuation, and refresh/reconciliation in `journal_graph_feed_plan`; filter before `root_todo` is populated. Keep row and preview APIs. | `receive_root_tree` already has the typed raw DTO and branches to previews; post-filtering the visible list would lose paging progress and do needless reads. |
| Worker / Overlay DB existing date and root reads | **No signature change needed for matching.** Reuse `Timeline.dates`, `Timeline.roots`, `preview_children`, `get_timeline_journals`, `get_timeline_roots`, and `get_timeline_children`. | `Dates` already takes range bounds and Roots already supplies both match fields. Preserve existing receipts and exact positions. |
| Worker / Overlay DB coverage freshness | **Gap to close for a definitive end/empty across an unbounded scan.** If matching is evaluated in the feed planner, propose a bounded scan witness via the existing Timeline read/check path, backed by a write-maintained Timeline-membership scope in Overlay DB. | `Journal_index` covers dates, not changes to candidates within a skipped day; `Page_roots` is per day and `Timeline_check` has a bounded proof budget. |
| Worker / Overlay DB tag picker | **Add graph-wide, paginated class/tag search** unless a bounded public API is exposed before implementation: e.g. `Tag_search { prefix; after }`, backed by `get_timeline_filter_tags ~prefix ~limit ~after`, returning `Graph.tag_summary` and a continuation. Resolve selected UUID labels by existing exact `Page` lookup where sufficient. | `get_pages` takes known UUIDs, and projected tag labels do not enumerate the active graph. `Task_statuses` / `Task_status_definitions` already cover status options; no change there. |

### Coverage witness proposal

Cover date membership and any visible-root eligibility, membership, move/order,
tag or task-status change that can affect the scanned result. For the first
contract a single journal-root membership scope may conservatively invalidate
across dates; this is a dedicated write-maintained scope, **not** the generic
graph projection revision and not an index of arbitrary filters. Retain existing
per-page and per-preview receipts for displayed payloads. Obtain the witness in
the same snapshot as each scan packet; fence by owner and normalized query, and
check coverage before publishing terminal results. A witness change or source
resync discards earlier coverage and withdraws a published empty result; restart
in bounded batches. Do not retain every skipped day's proof, and do not report
empty if validation, a budget or transport failed. An alternative changefeed
barrier is only sufficient if it demonstrably covers the same writes (including
local optimistic changes, remote sync, rollback/settlement and gap recovery).
No production API changes are made by this proposal.

Tag search should bind its continuation to graph owner, normalized input and
catalog version with a stable label/UUID order; ignore late responses for an old
search. Keep selected UUIDs visible/removable even if the current prefix omits
them or a lookup no longer resolves a label. Do not build a catalog by scanning
recent Timeline pages.

### Optional, not required for first implementation

Measure sparse matches and dense journal days before pushing the root predicate
down. If needed, extend the **same** `Timeline.roots` and `get_timeline_roots`
query with a normalized restriction (`Any` or tags/status OR); do not create a
parallel filtered feed. Bind Worker and DB continuations/proofs to the exact
restriction, preserve logical overlay membership/order and budget the candidates
examined, not only rows returned. Use a continuation when the scan budget was
spent before exhaustion. Pushdown alone does not prove freshness across days.

## Acceptance cases

- Apply distinct filters in graphs A and B. Switching graphs and restarting
  restores each independently; an unapplied edit is not restored. Reset then
  Apply on A only removes A's settings.

- `all` reproduces today's Timeline paging, grouping, order, rows and previews.
- A root with selected tag X but no status, or selected DONE with no tag, matches
  inside the range. A matching child alone and an out-of-range root do not.
- First two packets have no matches; the third does. It appears without a scroll
  gesture and without issuing child preview requests for the misses.
- A skipped day gains a matching root before the final empty reply, or after
  publishing empty: the old proof cannot leave a stale empty state on screen.
- Changing search text, applied filter, calendar boundary, or active graph cannot
  install late results belonging to the discarded request.
