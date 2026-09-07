# Indexed Journal Pagination

## Problem

Journal pagination enumerated every named page, hydrated complete page records,
sorted the complete journal collection, and computed a global scope hash before
applying an offset. A public-API audit of the downloaded mirror consumed 174,899
datom results for both limits 1 and 200, at approximately 450 ms. The contiguous
EAVT hydration path could include unrelated blocks between page entity IDs.

Worker applied date filters after pagination, and the App encoded “older than
this day” as a lower bound. Together these could produce empty or incomplete
older timeline pages. Journal scope revisions were cached by the App without
being used as a write precondition.

## Decision

`Database.get_journals` selects journals through descending indexed AVET reads,
merges active local creations, and hydrates only returned items. Its explicit
`from_day` and `through_day` bounds are inclusive and apply before selection.
The public result contains only `items` and `next_cursor`. Each item retains its
page revision. The limit remains 1 through 200.

### Indexed selection and exact hydration

`logseq_overlay_db/lib/database.ml` seeks `block/journal-day` through AVET at the
upper date boundary, using maximum entity and transaction components so a date
group spanning index nodes is included completely. Traversal stops at the lower
bound or when it leaves the attribute. Candidate validation reads only UUID,
name, title, journal day, and built-in classification fields. Existing journal
classification, including malformed and recycled-page handling, is preserved.
Repeated physical facts do not duplicate candidates or selected page fields.

Candidates are ordered by descending day and ascending UUID within each date
group. Active `Create_journal_page` intents replace authoritative candidates with
the same UUID before range filtering and selection. Inactive or remotely resolved
intents do not contribute. The operation selects the requested window and probes
one additional valid candidate; a complete same-date group may need validation
to establish UUID order. Group traversal uses one physical lookahead datom.

Selected authoritative pages use exact entity reads, with shared property
classification and reference UUID resolution. Local records receive the same
logical field effects as public page lookups. No global page list, named-page
scan, journal scope hash, or contiguous EAVT hydration range remains on this path.
An unindexed `block/journal-day` fails with `Invalid_read_request`; there is no
full-scan fallback. Performance fixture schemas declare the index.

### Date/UUID continuation and App bounds

The opaque journal cursor contains the last returned day and UUID, projection
revision, and query bounds. Continuations select strictly older dates, or larger
UUIDs on the same date. They seek directly to the last returned date and do not
visit newer dates. Same-date continuations rebuild that date group's UUID order.

Malformed cursors, obsolete journal offsets, and changed query bounds return
`Invalid_read_request`. Valid cursors from another projection return
`Stale_read_cursor`. Journal offsets and the 10,000-offset ceiling are removed;
children and page-tree cursors retain their existing contracts.

Worker forwards its range into overlay-db and has no post-pagination date filter.
`Journal_graph_runtime` converts an exclusive `before_day` into the preceding
calendar day as the inclusive upper bound, with lower bound zero. Month lengths,
leap years, year transitions, and the first supported day are handled explicitly.
Reversed ranges and ranges without candidates produce empty results. Existing
App stale-cursor recovery remains intact.

### Removed journal collection scope

The overlay scope variant `Journal_index_revision`, journal-result scope fields,
Worker scope/revision variants, codecs, conversions, and App scope caching are
removed. Protocol catalogs and affected consumer tests use the reduced response.
Journal creation requires the target page revision; collection-wide journal
preconditions are unavailable. Children/page-tree scopes and revisions remain.
`Journal_index_interest` change notifications still refresh journal queries.

The coordinated contract changes are in `logseq_overlay_db/spec/types.mli`,
`logseq_overlay_db/spec/database.mli`, their implementation, and
`logseq_db_worker/contract/protocol.{ml,mli}`. No `spec/*.ml`, Dune file, or
bonsai_flutter source was modified.

### Regression ownership and verification

A public worker reducer replay confirms that `Graph_request` simply emits
`Execute_request` with the unchanged journal request. Its state owns neither
index traversal nor hydration. Database regressions therefore exercise public
`Database` snapshots, local mutations, and authoritative batches. The App range
conversion is tested through `Journal_graph_runtime.submit`, its actual owner.
There is no duplicate database regression in runner, transport, UI, or E2E tests.

Tests observed failure before the cursor/range fix, and a later enlarged tie-group
regression exposed the reverse-seek prefix boundary before its fix. Final builds,
full tests, formatting, and public-interface access audits pass. The audit covers
12,050 journals, continuations after 10,200 results, 32-member date groups,
property-rich pages, interleaved entity IDs, local intents, repeated physical
facts, and missing index rejection. Expanding unrelated page/block entities from 12,050 to
100,000 leaves all non-storage data access counters unchanged.

On the downloaded mirror, limit 1 consumes 79 datom results and hydrates one page;
limit 200 consumes 3,129 results and hydrates 200 pages. These are instrumented
offline measurements, not App latency. Commands, raw results, regression evidence,
and measurement limits are retained in
[`docs/test-reports/2026-09-07-indexed-journal-pagination/`](../../../test-reports/2026-09-07-indexed-journal-pagination/README.md).

## Alternatives considered

### Forward attribute enumeration followed by sorting

This still processes the entire collection. Reverse AVET uses existing date
order and allows direct continuation seeks.

### Date-only cursor

Journal dates are not unique. Omitting the UUID tie-breaker can skip journals
when a page ends inside a shared date.

### Cached complete list with offsets

This retains global materialization and cache invalidation requirements. Indexed
selection bounds ordinary read work to the selected window, tie groups, invalid
candidates, and active overlay intents.

### Retaining a computed journal scope hash

The App did not use it for writes. Removing this capability eliminates whole-
collection membership processing and its protocol surface.

## Consequences

Journal reads scale with relevant candidates and selected hydration rather than
unrelated graph contents. Large same-date groups require complete identity
validation, and index-node storage accesses can grow with tree height. Active
outbox processing remains bounded by admission limits.

Journal collection-wide write guards and obsolete journal cursor formats are
intentionally unavailable, without compatibility decoding or migration. Page
write guards, structure scopes, change interests, and projection-bound cursor
recovery remain. Unrelated projection changes can still invalidate a cursor.
