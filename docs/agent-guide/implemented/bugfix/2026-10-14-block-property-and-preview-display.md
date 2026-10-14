# Block Property And Preview Display

## Problem

Graph.block already exposes typed, named property summaries. Journal_model discards all except status/asset metadata. Detail renders status in the title and property value blocks as ordinary children; Timeline previews those blocks. The existing native text widgets also use the parent four-line policy for children and spacious Detail typography.

## Decision

Preserve property summaries in the abstract Journal_model without changing existing constructors. Add these declarations to app/journal_model.mli:

```ocaml
val properties : t -> Logseq_db_types.Graph_types.property_summary list
val with_properties : t -> properties:Logseq_db_types.Graph_types.property_summary list -> t
val property_sources : Logseq_db_types.Graph_types.property_summary list -> (string * string) list
```

Expose the existing shared status/tag presentation in app/journal_row.mli:

```ocaml
val metadata : Journal_model.t -> Journal_view.View.t list
```

Use real logseq.property/created-from-property metadata and typed owning property references to classify value blocks. Preserve existing bounded pages, reference resolution, ten-level cycle guards, deferred loading and media lifecycle. Detail shows named non-hidden valued properties, including scalar values and bounded referenced values. Timeline omits property value blocks, caps parent/children at four/two native lines and three child previews. Detail uses three text tiers, clear block spacing and tighter within-block text. No Dune or spec interface changes.

## Alternatives considered

### Guess from title

Rejected because ordinary children can have property-looking names, and real properties can have arbitrary names.

### Shared global property side table

Rejected because it bypasses model ownership, can retain data across sessions, and complicates stale completion fencing.

## Acceptance criteria

- Public projection/reducer interfaces reproduce and regress property classification and named value preservation.
- Ordinary children named like properties remain ordinary children; custom-named properties retain semantic classification.
- Detail includes Yes and No values, property names, independent shared status UI, full body, and clear child boundaries.
- Timeline includes at most three ordinary child previews, each at most two lines, below a parent of at most four lines, without Show more.
- Existing depth/pagination/loading/media checks pass, followed by actual Simulator screenshots.
- Formal PR reaches CI terminal state and receives independent repo-skill review; no merge.

## Risks

- Referenced properties require bounded resolution using existing cached/read ownership. Hidden structural properties must remain hidden. Native line caps respond to width and Dynamic Type rather than truncating source strings.

## Questions

- None. The existing task authorizes this fix. These app interfaces are outside the protected spec/ directory; Dune and spec files remain untouched.

## Consequences

The model retains typed property metadata. Timeline classifies property values using created-from-property and stops collecting previews after three ordinary children; raw child ownership counts stay complete. Detail retains each value block as an owned row with a named attribute presentation, displays scalar properties, and uses the shared status/tag metadata component. Hidden properties and the already-rendered block/tags/status fields are excluded. UUID property values use the existing bounded, deduplicated reference cache only on Detail demand.

The native parent preview remains four lines; children use two subheadline lines with secondary color. Detail retains its three font tiers, tightens line heights to 31/25/20 points, and uses 24/20/18 point gaps between blocks. Native wrapping, scrolling and existing media ownership stay in place.

Regression ownership: property metadata is discarded in the public pure Graph projection before the route/reducer receives it, so valid Graph inputs reproduce it at that projection plus the public mounted renderer. The runtime reference owner is tested through submit/receive commands and responses, including a repeated closed-value UUID. Existing route tests cover ten-level/cycle, full-page reservation, continuations, 100ms loading and initial staging; existing mounted/media tests cover leases and bounded preview allocation. Tests failed for the expected missing behavior before production edits. A new built-in Tags regression also failed before its exclusion fix.

Manual acceptance on the current iPhone 13/iOS 26.1 Simulator confirmed property removal from Timeline, two-line subordinate children, independent status badges, named URL/steps fields, Yes and No values, full Detail text and distinct block spacing. Only read-only navigation occurred in the existing graph. Build caches were reused; SwiftPM's link product was explicitly regenerated after native object changes. The Simulator uses the existing host ARM64 complete-object restamp pipeline plus Simulator-compiled platform crypto, not a full cross-runtime ABI proof. Temporary diagnostics, screenshots, manifests and logs remain outside the repository and are excluded from public PR content.
