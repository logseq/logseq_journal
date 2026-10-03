# Journal Direct Image Gallery

## Problem

The user-provided IMG_1918.png was materialized from Library and inspected locally. Image asset block/title values such as camera.jpg and photo.png appear as Journal prose. Direct image children are rendered as separate thumbnail rows with large gaps instead of the selected C gallery. The graph projection drops asset/type metadata, and the row renders every child independently.

## Proposal

Keep graph asset/type metadata in the Journal projection. Hide only image asset titles in timeline prose, aggregate direct image children into their parent's existing C media area in sibling order, deduplicate by asset UUID, and retain each child's media event ownership. Keep ordinary child prose, non-image file rows, parent text, status and tags. Allow an empty graph parent with direct image children to project; keep ordinary blank roots skipped. Use existing bounded direct media queries and native LUI scrolling and fit/fill; do not add graph scans, alter notes, or update devices.

## Decision

Implement image composition in the existing Journal row/media boundary. The typed asset/type metadata matches Logseq's canonical string property schema and asset identity predicate. Index bounded tree results by parent once, preserve sibling order, and combine only direct image assets. Preserve original block/title values in storage and the model; suppress them only in image asset timeline prose. Keep LUI c484c672 fit/fill unchanged.

## Alternatives considered

### Filename matching

An ordinary note named photo.png is valid prose. Classification uses the typed graph asset/type property and actual asset descriptors rather than title text.

### Recursive media queries

They would collect deeper descendants and referenced page assets beyond this request. Keep existing per-root bounded direct queries and aggregate only known direct image asset children.

## Acceptance criteria

- Direct image children share one parent gallery in sibling order; image asset titles are absent even before files finish loading.
- Ordinary child content and non-image filenames remain visible. Parent prose and optional metadata survive.
- Duplicate parent references do not render the same image twice. Child image events and previews retain the correct owner/path.
- Empty parent plus image children renders without fake prose; deeper descendants are not swept into the parent.
- Mounted production component regressions fail on the original composition and pass on the fix, with late media arrival covered. Synthetic screenshots are labeled as component evidence when full App input is unavailable.

## Risks

- No change to media cache or synchronization lifecycle. Asset metadata without a supported image type remains ordinary content.
- XCTest input remains unapproved. Full App interaction cannot be claimed from synthetic component screenshots.

## Consequences

The row media callback now accepts direct image children. The media composition keeps UUID-based deduplication and per-item owner roots, so lazy file demand, Retry and native preview use the original child. Zero-height native observation nodes in an overlay give newly mounted children their own appearance lifecycle without adding row height or gallery gaps. No recursive graph query or scrolling geometry tracking is introduced.

## Regression boundary

Journal_timeline_state's public pure events apply correctly projected entries and do not own the discarded graph property or mounted media grouping. Journal_media's public pure reducer owns file leases, not parent/child composition. Reproducing these defects there would require injecting an already incorrect projection. Exercise the narrow mounted Journal_row/Journal_media_view boundary with valid Graph.block input through public Journal_graph_projection.timeline_entry_page, public UI events, and late view updates. Do not duplicate these cases in runtime/transport/E2E tests.

## Questions

None. The user explicitly authorized this correction and local tests. Device installation and automated XCTest input are outside this authorization.

## Implementation evidence

All four new mounted cases fail on the prior composition: child asset titles, pre-file title flash, an empty parent omitted from projection, and a top image asset's filename body. All 17 semantics cases now pass, including sibling ordering, UUID deduplication, ordinary filename prose, non-image filenames, exact native preview path, late child metadata arrival without another parent appearance, late file arrival and asset event ownership. Journal build @all/native_embed, final dune runtest, changed-source ocamlformat --check and git diff --check pass. The existing blank-root sparse-pagination test remains passing.

Two actual Simulator PNGs use the production Journal projection/row/media/header and LUI Apple renderer with explicit synthetic examples. Pixel checks find a gallery circle 128x130 pixels and portrait thumbnail 104x104, consistent with proportional rendering. The overview viewport shows its first two rich rows; the ordinary filename prose and both file cards are fully visible in the edge capture. These are isolated component fixtures, not signed-in graph UI acceptance. Actual drag/swipe and full-App interaction remain unverified because XCTest input is not approved.

The user reference and all evidence/harness outputs remain outside Git in the task workspace. The local report copy is under the existing ignored docs/test-reports/ directory; build outputs use existing _build and swift/.build ignores. No existing graph data was modified, no real App package or phone was updated, and no push/PR/merge occurred. The global decision-document check reports only the pre-existing 2026-09-28-bottom-lui-capsules.md missing required sections; this decision validates independently.
