# Adaptive Journal media layout C

## Problem

Full-width images dominate timeline entries. Fixed dimensions combined with an unconstrained resizable Apple image distort the original aspect ratio. Users need readable text, compact single-image thumbnails and a discoverable multi-image strip.

## Proposal

Implement the user-selected C layout in OCaml and LUI: one image beside the text, several images in a native horizontal gallery beneath full-width text, proportional crop in thumbnails, native full-file preview. Add a public fit/fill file-image capability in LUI, defaulting to proportional fit. Keep optional task/tag metadata and file rows. Add only synthetic data to the verified OCaml sync test graph using supported authenticated CLI/service APIs. Do not repair cache lifecycle in this change.

## Decision

Implement the reviewed C layout with native LUI rows and scrolls. The shared file-image fit/fill property owns proportional rendering; Journal owns the adaptive arrangement.

## Alternatives considered

### All images beside the text

Very compact but hides multi-image content and narrows long prose.

### All images beneath the text

Keeps prose wide but makes single-image entries unnecessarily tall.

## Acceptance criteria

- One image uses a 102pt square to the right; multiple images use a 190 by 90 native horizontal strip below the body.
- Thumbnail crop and full preview preserve source proportions for landscape and portrait images.
- Optional metadata, file-only, empty-body and unavailable-media cases stay readable.
- Targeted behavioral tests fail before the change and pass afterward; actual Simulator evidence is identified separately from design previews.
- Test graph identity is verified before additive fixture writes; originals remain intact.

## Risks

- Cropping intentionally hides edges; the full preview shows the whole file. Multi-image scrolling must retain normal row actions elsewhere. The current media item has no reliable filename, so existing type fallback remains truthful. Remote writes depend on a supported authenticated sync session.

## Consequences

Journal requires the companion local LUI change before this feature can ship. The current runtime projection still lacks a guaranteed original filename, so file cards keep truthful type labels and optional actual sizes. Six synthetic test cases were created in the verified ocaml-sync-test graph, but remote acknowledgement is blocked by its missing E2EE unlock password. No credentials are read or copied.

## Questions

No unresolved design questions: the user selected C and explicitly authorized implementation plus additive synthetic test data. Graph identity and access are execution checks, not assumed approvals.

## Implementation evidence

The production layout owner is the mounted Journal media/row view; public pure reducer events do not own frame or placement state. The two new narrow mounted-view cases failed before implementation and all 13 Journal semantics cases pass after it. LUI validates fit/fill at the public protocol boundary and rejects stretch; 47 OCaml cases, five schema-generator cases and 152 Apple tests pass. Workspace and actual iOS Simulator builds succeed. Native synthetic screenshots confirm both portrait and landscape markers remain round, the multi-image strip exposes the next image, and empty body, optional metadata and clamped long text remain readable.

Full Journal runtest initially hit one pre-existing WebSocket transport test EOF; that exact test passed on isolated retry. Full authenticated graph UI, physical iPhone and actual drag/swipe interaction remain unverified: the production Simulator App has no authenticated session and the CLI reports missing-e2ee-password. Synthetic component screenshots are explicitly distinguished from the full App and earlier visual proposals. Evidence is stored outside Git. No cache lifecycle repair, merge, push, PR or physical-device installation is included.
