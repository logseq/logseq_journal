# Retain AppBar Across Root Destinations

## Problem

The user reports a brief header/AppBar flash when switching between Journals and Favorites on macOS.
The user confirmed that switching flashes both when the destinations are at the top and when returning to a destination with a saved nonzero offset.
The requested behavior is to retain the AppBar instance and update only the parts that need to change.
Ordinary Flutter rebuilds, layout, and painting remain permissible; the goal is to avoid unnecessary subtree disposal and incorrect intermediate visual states.

### Investigation evidence

- `app/application.ml` gives the root scroll view a destination-dependent key: `journal-scroll` or `favorites-scroll`.
  The AppBar is inside that scroll view, so its stable `journal-header-app-bar` key cannot preserve its element across replacement of the parent subtree.
- `flutter/lib/journal_root_navigation.dart` retains two controllers and cached offsets, but newly created `_RootScrollPosition` instances default to zero and disable automatic offset restoration.
  Destination changes restore the cached offset through `addPostFrameCallback` and `jumpTo`, after the initial frame has been drawn.
- The installed `material_ui` AppBar selects `surface` or `surfaceContainer` according to its scrolled-under state.
  Drawing a zero-offset frame before restoring a nonzero offset could contribute to flashing when returning to scrolled content.
  It cannot alone explain the user-confirmed flash when both destinations are at the top.
- `app/journal_header.ml` uses equal expanded and collapsed heights, with floating and snap disabled.
  A normal expanding/collapsing toolbar animation does not explain this path.
- The existing independent-scroll-offset Flutter test passed locally on macOS, but its `pumpAndSettle` assertions only verify the settled result.
  It does not establish that intermediate frames are correct.

At proposal time, the visual root cause had not been confirmed by a live macOS reproduction.
The then-running Release application remained at its sign-in screen during inspection, preventing destination switching.
The code establishes a suspect frame sequence, not a completed visual reproduction or proof that it explains every reported flash.

### Implementation investigation

Prioritize reproducing the both-at-top case, where nonzero offset restoration cannot explain the symptom.
Inspect consecutive application and Flutter frames for AppBar/control remounts, mount-time animations, material/background changes, and title or toolbar geometry changes.
These are investigation candidates, not established causes.
Identify the visible transient and its production owner before choosing the regression boundary or declaring the proposed retention change sufficient.

## Decision

The implementation retains one root scroll view and one native SliverAppBar within each graph lifetime.
Use a destination-independent scroll-view key in `app/application.ml`, retaining the existing header key and stable surrounding structure.
Switch the body slivers and update the title and any genuinely changed header properties.
Retain unchanged account controls, synchronization progress, and error controls rather than replacing their subtrees on destination selection.

Rework the private native scroll owner in `flutter/lib/journal_root_navigation.dart` to use one stable controller/ScrollPosition and two saved destination offsets.
Changing only the scroll-view key is insufficient: Flutter can attach the retained ScrollPosition to another controller without creating a destination-specific position.

On destination selection, save the outgoing position, cancel its ongoing motion, clear user-scroll intent, and queue the incoming destination's saved offset.
Apply the queued correction during layout using the target content's dimensions, before painting, and clamp it to the valid scroll range.
Use the ScrollPosition layout-correction contract to request another layout pass when necessary; do not defer destination restoration until after painting.
Ensure correction runs even when the two destinations have equal content dimensions.

Preserve Favorites anchor-delta restoration on revision changes using the same pre-paint correction path.
Updates while Favorites is inactive adjust its saved offset without moving Journals.
Rapid destination changes must replace stale pending restoration, and graph changes must reset the native scroll owner and both saved offsets.
Restoration and layout corrections must not emit user-scroll intent or overwrite the other destination's saved position.

Keep the native SliverAppBar's existing appearance and legitimate scroll-dependent background behavior.
Do not promise zero `build` calls or zero repainting when text, layout, synchronization, or scroll state changes.
Public application interfaces and the native extension payload remain unchanged.

This decision implements AppBar instance retention and pre-paint destination offset restoration.
The user confirmed both reported flashing scenarios are resolved in the rebuilt macOS Release.
The implementation complies with `docs/ux-guidelines.md`. No OCaml files under `spec/`, dune files, or bonsai_flutter OCaml source were modified. The obsolete destination-switch restoration path was removed.

## Alternatives considered

### Initialize new positions from cached offsets only

This could remove the zero-offset frame for remounted scroll views, but would still destroy the AppBar subtree on every switch.
It does not satisfy the requested instance retention.

### Keep two controllers and only stabilize the scroll-view key

The retained Flutter Scrollable can transfer the same position between controllers.
This does not independently restore destination offsets and can associate the outgoing position with the incoming destination.

### Keep both complete destinations mounted

Keeping two full scroll views mounted would retain two separate AppBars and inactive body trees.
A single retained header and explicit native offset ownership better match the requested change without introducing inactive-view lifecycle ownership.

### Force a constant AppBar background

This could conceal a background flash but would change legitimate scroll-dependent appearance and leave the incorrect intermediate position intact.

## Acceptance criteria

- Switching destinations within a graph retains the root scroll view and native AppBar instances, as well as unchanged header controls.
- Switching with both destinations at the top produces no header flash; restoring nonzero offsets must also be free of incorrect intermediate visual states.
- The title changes correctly between the journal date and Favorites; account, error, and synchronization behavior remains functional.
- The first painted frame after a switch uses the destination's saved position, clamped to its current content range, without a transient zero or outgoing-destination position.
- Journals and Favorites retain independent offsets, Favorites retains anchor corrections, and a new graph starts with fresh scroll state.
- Rapid switching and switching during a fling do not carry outgoing motion or user-scroll events into the incoming destination.
- Existing navigation and header checks pass, and live macOS switching confirms the reported flash is resolved once the application is signed in.

### Validation boundary

Before adding regression tests, exercise the public application reducer's selection events and inspect its state and effects to confirm the ownership boundary.
The current suspected defect executes in Flutter element lifecycle, ScrollPosition correction, and AppBar layout; the application reducer owns destination selection but not those native states.
If the public pure reducer reproduces the actual defect, follow the repository rule and test it only there.
Otherwise, document that missing native ownership boundary and place regression coverage at the narrowest Flutter boundary that executes the defect.
Do not move production ownership merely to change test classification.

For the expected native boundary, extend existing Flutter tests with consecutive real application frames from the same application session, not separately mounted destination fixtures.
Assert retained AppBar/control identity, title updates, and layout-time position on individual pumps before settling.
Reproduce and assert the actual both-at-top visual transient; instance retention and correct offsets alone do not prove that the reported flash is fixed.
Include both destinations at the top, returning to nonzero offsets, equal-size content, empty/short/long destinations, reduced content bounds, Favorites refresh while active and inactive, rapid switching, switching during motion, and graph reset.
Verify that programmatic restoration does not emit user-scroll samples.
Write the failing regression before implementing the behavior, and preserve existing tests.

Run the focused navigation and header suites, relevant OCaml frame-generation checks, Flutter analysis, and a macOS build through the installed `bonsai-flutter` tool.
Complete live macOS verification after sign-in, then validate decision documents with `spec-dev-tool check --all`.

### Implementation progress

- Boundary investigation: ran `dune exec test/application_view_test.exe -- test "root navigation"`; both existing public reducer lifecycle cases passed. Selection, scroll samples, completion, and graph replacement expose destination and control state, but no Flutter element identity, paint, native activity, or layout correction state. The native defect cannot be reproduced at this public pure reducer boundary. Regression assertions belong to the Flutter scroll owner and renderer; OCaml exports supply consecutive production application frames without duplicating native assertions.
- The failing consecutive application frame regression found a second disposal owner: the scaffold serializes its optional Capture FAB before its navigation and body slots. Removing Capture shifted the unkeyed body to another child index and remounted the complete scroll subtree even after the scroll-view key was stabilized.
- The implementation keys the existing body overlay and navigation bar and retains the root scroll-view key. Horizontal padding now belongs to the overlay base, with equivalent banner offsets, so the keyed body is the scaffold child without adding a wrapper or retaining a hidden Capture subtree.
- The native owner now retains one controller and position per graph. It snapshots the outgoing offset, cancels activity, and replaces pending restoration. `applyContentDimensions` clamps against the target layout, calls `correctPixels`, and requests another layout pass before painting. The former post-frame `jumpTo` restoration and destination controller list have been removed.
- Existing native offset and intent fixtures now use the retained scroll key. Their coverage is preserved. New regressions live in the existing navigation suite, as required by the repository source-boundary allowlist.

### Validation outcome

- RED: before implementation, the same-session application frames disposed the AppBar on selection; the paint probe observed the outgoing `700` offset on the first frame of an incoming destination saved at zero. All eight native retention scenarios failed before the implementation. Stabilizing only the scroll key still failed application AppBar identity until the scaffold body was keyed.
- GREEN: all 142 tests in the focused navigation and header suites pass, including all eight native scenarios, consecutive production application frames, retained AppBar/account/sync-progress elements, title updates, equal extents, empty/short/long and reduced content bounds, active/inactive Favorites anchor deltas, graph reset, successive selection builds before layout, fling cancellation, and absence of restoration-generated user samples.
- The top header raster remains identical between each destination's first painted frame and checks at 16, 32, and 200 milliseconds. The legitimately animated synchronization strip is outside this raster region. Existing header suites continue to cover error controls, synchronization phases, themes, text scaling, and layout.
- `dune build @all`, `dune runtest`, focused Flutter tests, Flutter analysis, OCaml/Dart formatting, `git diff --check`, and `spec-dev-tool check --all` passed at completion.
- Built macOS through the installed `bonsai-flutter` tool in Debug and Release. The previous running Release was built on September 7, before the September 8 NavigationBar feature; it was replaced with the new Release built at 21:16 on September 8.
- Live validation used the authenticated `Lambda-RTC-test` graph. Startup restored the recent graph, both top destinations switched correctly, and Journals and Favorites returned to their distinct nonzero positions with the appropriate native scrolled-under background. The account control remained present.
- The user explicitly confirmed that neither the both-at-top switch nor the nonzero-offset return flashes in the new Release. This confirmation closes the reported visual acceptance criterion; the frame regressions independently establish disposal and pre-paint position ownership. It is not a claim that every individual GPU frame of the original symptom was recorded.

## Consequences

- A correction based on the outgoing content's extent can incorrectly truncate the incoming destination's saved offset.
  Restore against the target layout and verify the first painted result.
- A pending correction can be skipped when content dimensions are unchanged or can survive a rapid destination switch unless it is explicitly consumed or replaced.
- Native offset listeners and outgoing scroll activity can misattribute position changes after selection; correction bookkeeping and event ownership must be tested together.
- AppBar background differences that correctly reflect the target scroll state should remain; acceptance distinguishes those from an incorrect intermediate flash.

## Questions

Answered by the user: the flash occurs in both cases, including when both destinations are at the top.
No additional user decision is currently required.
Implementation validation identified the additional scaffold-body disposal path, verified retained native state and pre-paint restoration, and obtained user confirmation that both reported flashing scenarios are resolved in the new macOS Release.
No questions remain.
