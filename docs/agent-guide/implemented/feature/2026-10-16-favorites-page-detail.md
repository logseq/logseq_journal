# Favorites page and outline detail

## Problem

Favorites page rows cannot open detail, and favorite outline titles do not use the shared mldoc/reference presentation. Detail root reads and append/copy confirmation currently assume outline blocks.

## Proposal

Keep the public Load_detail request and existing route, staging, grace timer, traversal and asset owners. Resolve an outline root through its existing read, falling back to get_page only on a real outline miss; reuse known page identity for subsequent loads. Adapt page roots to the existing display model with id equal to page_id, page properties and a page revision. Children retain their existing bounded reads. Page append uses page and children-scope preconditions and confirms the exact page parent; outline append keeps block preconditions. Page root menus omit outline-only deletion. Extend the existing Copy reducer root lookup to accept pages without introducing another traversal.

The Favorites root omits the bottom-right Capture opener; Journals keeps its root opener and page/outline detail keeps its own Capture. This is a context-based rendering choice in the existing OCaml header, without another state or interface. No public pure reducer owns whether a header control mounts; test that missing boundary through the public header/Application rendering interface.

Favorites use one native list with the existing page document symbol and a small solid bullet for outline blocks, whole-row LUI list items, no trailing chevron, no status/media/summary, and single-line tail truncation. Favorites titles use the shared Title.render lookup and Title.plain output in ordinary LUI text; UUID references remain non-clickable, and ordinary URLs retain the prior Favorites text behavior. The list uses only Lui_elements.list/list_item, label, text and icons; no Journal Swift extension implements the list. Keep the existing page-first UUID reference reader, cache, deduplication, epochs and graph reset. Preserve ordinary URL semantics and deprecated double-parenthesis behavior.

## Decision

Use the shared detail flow for both Favorite target kinds, with one internal page-root adapter and exact page-aware mutation confirmation. Use the existing LUI list and single-line text policy, reuse mldoc/reference caches, and omit Capture only for the Favorites root context. Outline rows use the existing Dot symbol at 6pt inside an 18pt icon slot, preserving alignment with unchanged page icons and avoiding a task-control appearance.

## Alternatives considered

### Separate page-detail state machine

Rejected because navigation, initial publication, loading grace, pagination and draft ownership already have one canonical owner.

### Query both page and outline for every root

Rejected because known root identity and a single fallback avoid duplicate reads.

## Acceptance criteria

- Page and outline Favorites enter the same detail flow and return to Favorites; empty page roots render naturally.
- Existing 100ms grace, complete initial body publication, independent asset states, ten-level cap, cycle protection and 128-item pages remain intact.
- Page append and copy use the selected page identity, including empty pages and journal pages; stale navigation/graph completions cannot publish elsewhere.
- Favorites references resolve journal page date titles and outline titles through the shared resolver; repeated targets share reads, absent targets and obsolete results retain existing fences.
- Run the public pure owner tests first, preserving red evidence before implementation; verify Simulator with independent synthetic data/device and report its compilation and coverage boundaries.
- No protected spec, Dune or lock edits; no push, PR, production install or real graph/cloud writes.

## Risks

- Page roots must never be mistaken for outline mutation targets. Existing model children on a page have parent_id=None, so append completion matching must also verify page_id. Native build inputs need coordinated reuse and retain experimental ABI limitations.

## Validation

The pre-bullet commit 10a8d59 passed 139 runtime, 104 mounted Application and 45 route/detail cases, with native source hashes bound to isolated run-2_x07chr. The later icon-only change passed the narrow public render regression (RED then GREEN) and a single final-source native list screenshot case using run-ipiiemd4; the full interaction matrix was intentionally not repeated. The dedicated ECFF synthetic Simulator passed A/B (list, both entries/Back, empty page, ten-level body and 128 continuation) and C/D (slow body with usable header/Back, switching while the slow request is pending, exact page/outline text append and clipboard subtree). The list omits Capture while page/outline detail retains it. The controlled fixture validates page versus block preconditions and logs exact parent/page identities. Repeated UUID references use one page-first lookup per launch. Earlier fixture inconsistencies and test-selector failures were corrected; final accepted runs have zero failures.

## Consequences

The implementation reuses the existing state owners, bounded traversal and cache. Page roots are display adapters identified by id equal to page_id, with page revision/scoped append confirmation; outline-only actions are omitted for them. No protected spec, Dune, lock or Swift source changes are needed. Native evidence uses in-memory protocol responses, not persisted graph data or cloud writes. Text Capture/Copy was exercised; native picker/assets and complete iOS ABI are outside this probe. The exact loading threshold and negative traversal/ownership paths remain covered by public owner tests. Host ARM64 restamping remains experimental with cross_abi_validated=false and production_source_validated=false.

## Questions

None. The user selected single-line truncation, replacing the two-line proposal, and explicitly removed the Favorites root Capture opener. The user subsequently requested a small solid bullet instead of the hollow outline icon at 2026-10-16 07:28:59 UTC. The user also authorized updating only the dedicated ECFF synthetic Simulator on 2026-10-16 at 07:07:23 UTC. That installation retry was approved; final current-source acceptance is complete. No push, PR, phone/production install or real graph/cloud writes were authorized or performed.
