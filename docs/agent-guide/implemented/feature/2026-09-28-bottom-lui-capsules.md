# Shared LUI Capsules

## Decision

Render the iOS Journals/Favorites capsule and Capture button with
`Lui_element_combine.buttons` in page content. Remove their bottom toolbar
items. Use SwiftUI's native `safeAreaInset` to place the controls above the
home indicator and reserve scrolling space. Do not add another glass surface
around either composite. Hide the controls while Capture is expanded.

Account/Error use the same composite in a page-top layout on both destinations.
Remove the additional SwiftUI circle glass effects and the Favorites toolbar
items. Keep the Favorites title as native page content. The page chrome now
has content, a single combined control slot, and progress; retire the separate
account/error slots and the legacy extension icon-collapse/40pt sizing wrapper.
Header controls also use ordinary page layout on macOS.

Block detail uses a Back capsule and a shared Append/Attach capsule in a native
top safe-area inset, with no toolbar or additional material. The attachment
extension hosts the page and its native `fileImporter`; it no longer creates
its own Button. The scoped Attach action advances the existing picker request,
with write/delete/status/save guards. Native presentation also rejects a new
request while an import retains its security-scoped URL.

## Ownership and verification

`Application.Root_navigation` owns destination and Capture transitions, but
its public reducer has no material, view placement, or safe-area state. Those
events cannot reproduce the rendering defect. `Journal_header.view` owns
control placement, and `JournalChrome` owns native layout. Cover the narrow
header mounting boundary through its public view and LUI event interfaces:
both destinations, Capture open/closed, disabled Capture, 44pt cells, and
delivery of the existing actions. Verify native safe-area layout and glass
visually on iOS.

The expanded header test covers the four Account/Error availability combinations
on both destinations, with Capture enabled, disabled, or expanded. It asserts
that page content creates no toolbar, each composite supplies one glass surface,
the Account retains its native menu trigger, and Error presses still dispatch.

The public `Journal_routes.open_detail` and `apply_detail_response` transitions
own detail loading and content, but have no toolbar/material state. They cannot
reproduce the visual defect. Mount the actual `Application.detail_page` through
its public testing entry with routes produced by those transitions. Verify
Back, Append, and Attach hit cells and action delivery for loading, read-only,
and writable detail. The regression failed on the old toolbar before the view
was changed. Verify the native picker and header layout visually on iOS.

`spec-dev-tool --help` could not run because the executable is not installed.

## Results

- The header regression failed before implementation because Journals was
  inside a toolbar. It now passes for Journals and Favorites, with Capture
  enabled, disabled, and expanded. The expanded regression also failed before
  the top controls were changed, and now passes for all four Account/Error
  availability combinations. All action cells remain 44pt.
- `dune build @all app/native_embed.exe.o`, the iOS SwiftPM build, formatting checks,
  and signing verification passed. The new app was installed and launched on
  the connected iPhone 13. The Journals device screenshot confirms matching
  capsule heights and single Account/Capture surfaces. Favorites and Error
  availability are covered by the mounting regression.
- Full workspace tests retain one pre-existing source-boundary assertion
  requiring `V.progress` in the unchanged `app/journal_timeline.ml`. The sync
  error source check now uses the surviving body declaration as its end marker.
- The detail mounting regression passes for loading, read-only, and writable
  routes. Back always dispatches, while Append/Attach only dispatch when a
  writable detail is loaded. OCaml workspace and iOS SwiftPM builds pass after
  removing the native attachment Button and accepting page children. The
  rebuilt signed application was installed and confirmed running on the
  connected iPhone 13.
