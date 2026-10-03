# Stable Timeline Image Slots

## Problem

The production Timeline renderer changes image frames with presentation state. A real iOS Simulator harness using Journal components measured single-image Placeholder to File increasing the affected content height by 47.333 pt; Hidden to File increased it by 81.667 pt. Two known image children likewise changed height even when their count remained fixed. An empty preview node also adds a 12 pt content-column gap only after descriptors arrive. FileImage decode alone and text controls stayed stable.

The presentation reducer owns downloads and file availability, not layout frames. Its public events cannot reproduce an incorrect native frame: the narrowest owner executing this defect is Journal_media_view, reached through Journal_row's public graph metadata and mounted LUI output. Regression tests belong at that renderer boundary. The external Simulator measurement remains diagnostic evidence, not a second production regression suite.

## Decision

Use existing graph asset/type and UUID metadata to reserve image slots before runtime descriptors arrive. Single images retain the C layout's 102 by 102 right thumbnail; multiple images retain the 190 by 90 horizontal gallery. Every pending, Placeholder, Hidden and File image presentation uses that same outer slot. Preserve proportional fill and the native full-file preview. Mount preview outside the content column so availability does not introduce a spacing child. Keep descriptor identity and owner routing intact; never invent asset checksums, versions, dimensions or files.

Extend existing Journal PR #43. The user explicitly authorized fixing the measured cause, pushing the branch and verifying its exact-head CI. No PR merge, phone install, LUI review fixes, scroll-anchor coordination or other feature changes are included.

## Alternatives considered

### Scroll position compensation

Rejected: it masks changing layout rather than correcting it, requires custom geometry coordination and is outside authorization.

### Reserve space only after a descriptor arrives

Rejected: the graph already identifies root/direct-child images, so this leaves a preventable initial layout transition and the one-to-two descriptor switch.

## Acceptance criteria

- First capture failing renderer regressions using public Journal_row and mounted LUI interfaces.
- Known single/root-image and two-image graph entries reserve final dimensions even before runtime metadata, and retain them through separately arriving descriptors, Placeholder, File, Hidden and repeat reload.
- Existing image ordering, UUID deduplication, lease/event owner, retry, preview and file-card tests pass.
- Repeat the six original production-component Simulator cases; the measured row and following-row frames remain stable for unchanged known image graph metadata. Record controls and repeat/reload states.
- Build and full tests pass; push the existing draft PR and follow exact-head macOS CI to terminal.
- Preserve baseline diagnostics, save before/after evidence to Library, and report unresolved scope and read-only LUI review findings.

## Risks

- Intentionally reserved space remains visible while a known image cannot be downloaded; a compact placeholder communicates that state.
- A truly new image added to graph metadata or newly discovered unclassified attachment may legitimately change layout. This fix does not promise every scroll jump is eliminated.
- Native row measurements use synthetic presentation transitions, not a real phone/network completion sequence or gesture test.

## Questions

None. The user's authorization and measured scope are explicit.

## Consequences

The three public renderer regressions failed against the original implementation and pass after the fix; all 20 renderer cases, the complete existing test suite, and all/native-embed builds pass. The first restricted test attempt was interrupted after transport fixtures reported denied loopback binds; the full suite passed with the required local networking capability, without skipping or altering tests.

Seven real-component Simulator cases ran ten phases each: the six original cases plus a separately named known-single-child control. Root-image and known-single content heights stay at 118 pt; both gallery cases stay at 204.333 pt. The following row position stays fixed through absent runtime descriptors, separate arrivals, Placeholder, File, Hidden, clearing descriptors and repeated reload. Decode-only and text controls remain stable. The original short-body case intentionally has no graph image metadata: first descriptor discovery still changes 36.333 to 118 pt, while every availability transition with that descriptor retains 118 pt. That discovery/removal boundary is outside this fix's guarantee.

The full-file preview lives in a zero-size overlay rather than adding a 12 pt spacing child. Proportional fill and the selected C layout remain intact. Evidence is synthetic and stored outside Git; the baseline is preserved. No phone install, PR merge, custom scroll coordination or LUI review fixes were performed. Exact-head hosted CI is tracked separately on draft PR #43.
