# Long-press Copy and block image group preview

## Problem

The user requested copying a selected block with every descendant, independent of mounted/collapsed rows, and opening the current block's images together from the tapped image. Journal's previous file preview supported a single URL.

## Proposal

Add Copy to Timeline and Detail block context menus and to block favorites. Resolve favorite membership to its block UUID. Keep page favorites as navigation only. A public immutable Copy state machine reads the selected root and all child pages in graph order, traverses depth first, and checks the graph identity/generation/projection revision before and after the read. Copy exact raw root text; prefix descendants with two spaces per depth and `- `, aligning multiline continuations after the marker. Empty text is valid. Reject invalid topology, pagination, UTF-8, read errors and oversized results rather than truncating or changing the clipboard partially. Cancel on graph retirement, sign-out, deletion or a newer Copy, and ignore stale Worker completions.

Use Journal's application-owned LJP2 platform channel for an acknowledged clipboard write. Implement with UIPasteboard/NSPasteboard without reading the clipboard or extending LUI. Preserve the existing 256 KiB platform envelope bound.

For image previews, collect only ready images from the tapped block's existing image order, set the selected index to the tapped image, and retain a separate preview reference for every group member before releasing the previous group. Exclude PDF/text and unavailable slots. Close if any captured member changes; reopen to include images that finish downloading later. Use the system QLPreviewController with an immutable image data source and initial selected index on iOS, and native SwiftUI QuickLook on macOS, retaining the previous single-image/PDF path and basic macOS support. Do not introduce custom scrolling, Photos permissions or unrelated cache-lifecycle changes.

## Decision

Implement the proposal within Journal, preserving existing business actions and shared APIs. The user explicitly authorized this scope.

## Alternatives considered

### Copy mounted rows

Rejected: collapsed descendants and later child pages would silently disappear.

### Reuse the shared single-URL LUI file preview for a group

Rejected: its public API has one path. A Journal-owned native extension avoids changing a shared API used by other apps.

## Acceptance criteria

- Pure Copy tests exercise ordering/pagination, deep and multiline/empty content, cancellation/replacement, errors, graph changes, malformed topology and size bounds.
- Mounted Application tests verify Timeline/Favorites/Detail menus reach the clipboard through actual Worker requests; page favorites do not expose Copy. This adapter owns menu routing and Worker cancellation, neither of which can be reproduced by the pure traversal owner.
- Mounted media tests verify clicked index, same-block membership, independent file references, unavailable/PDF exclusion and single-file compatibility. Native QuickLook is checked separately on synthetic Simulator resources.
- Changed-file formatting, builds, related tests and full tests are recorded. Full-repository baseline formatting differences and native gesture/lifecycle limitations remain explicit.

## Consequences

Copy traversal and actual Timeline/Favorites/Detail Worker-to-clipboard routing pass, including replacement cancellation. Clipboard codec round-trips through Swift and OCaml. A synthetic Simulator fixture confirms the clicked second image, native list membership without PDF/cross-block mixing, actual green/purple image rendering, system Share and normal close. Native initial-index assertion failed before load/reload ordering was fixed and remains in the external fixture. CUA dragging did not demonstrate paging; real swipe gestures, personal graphs and physical devices remain unverified. No XCTest input was used.

Full regression tests pass when existing loopback transport fixtures are allowed. Changed-file formatting, OCaml build/native complete object, the native mutation runner, all production iOS Swift source compilation and iOS/macOS preview typechecking pass. Full-repository formatting and one older agent document have pre-existing baseline differences, recorded externally.

## Risks

- Child reads are bounded individually, and clipboard output is bounded; concurrent graph changes fail the final revision check rather than produce a mixed snapshot.
- The inherited single-file lifecycle has no native dismissal-completion handshake. Group references preserve all URLs while presented, but row disposal/retirement versus native close animation remains a separate existing limitation; no older unpublished fix is imported.
- A visible Save action requires a separate user decision about Photos versus Files; the existing system Share menu is not claimed as that feature.

## Questions

None for Copy and image grouping: the user explicitly authorized them. The separate Save destination decision remains outside this proposal.
