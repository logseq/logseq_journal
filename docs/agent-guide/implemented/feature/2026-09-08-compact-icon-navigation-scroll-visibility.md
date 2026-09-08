# Compact Icon Navigation and Scroll Visibility

## Problem

The root NavigationBar occupies too much vertical space for two destinations.
The implemented Material NavigationBar uses its default 80-point content height,
plus the native bottom safe inset. Persistent labels increase the visual weight.
The current closed-book Journals icon also needs replacement.

On 2026-09-08, the user requested:

- Reduce the navigation height to the minimum.
- Show icons only, without persistent text labels.
- Present several replacement Journals icons for selection.
- Hide navigation while scrolling down in Journals or Favorites and show it while
  scrolling up, using the same trigger mechanism as the Capture FAB.
- Record the work as an exploring document.

The initial exploration changed this document only. On 2026-09-08, the user
subsequently requested implementation of the approved proposal.
The preceding behavior is recorded in
`docs/agent-guide/implemented/feature/2026-09-08-journals-favorites-navigation.md`.

### Pre-implementation ownership and evidence

| Owner | Evidence and implication |
| --- | --- |
| `flutter/lib/journal_root_navigation.dart`, `buildJournalNavigationBar` | Renders the OCaml destination descriptor using the built-in Material NavigationBar. It currently omits `height` and always shows labels. It explicitly restores the raw native bottom inset. |
| Installed `material_ui 1.1.1`, `lib/src/navigation_bar.dart` | Computes content height from the explicit value, theme, or default 80; SafeArea surrounds that content. An explicit smaller height is supported without a framework change. |
| `app/journal_visual_tokens.ml`, `hit_regions.minimum_target` | The app already uses a 44-point minimum target. This is the proposed minimum content height, rather than the Material default recommended target of 48 points. |
| `app/journal_timeline_state.ml`, `update_capture_fab_scroll` | Owns the public pure FAB trigger. Same-direction travel accumulates; reversal starts accumulation in the new direction. Positive travel of 24 points changes Extended to Compact; negative travel of 24 points changes Compact to Extended. At `pixels <= 0`, it resets to Extended. Zero delta preserves the current state away from the top. |
| `app/application.ml`, Scroll dispatch | Sends root scroll samples to one `capture_fab_scroll` value. Both root lists currently use this dispatch path. Reusing one unqualified value would let Favorites scrolling change the retained Journals FAB presentation. |
| `flutter/lib/journal_root_navigation.dart`, `JournalRootScroll` | Owns independent native scroll controllers, restoration, and refreshed anchor jumps. These programmatic movements must not act as user scroll intent. |
| `test/journal_timeline_state_test.ml` | Already tests the public FAB trigger's threshold, reversal, zero delta, and top reset. Preserve those tests and their production ownership. |
| `docs/ux-guidelines.md` | Prefer appropriate built-in Flutter components, keep at most three dividers, and open the last graph immediately. |

## Proposal

### Minimum height and icon-only destinations

Set the built-in NavigationBar content height to **44 logical points** and its
label behavior to `alwaysHide`. Render each destination icon at 24 points,
vertically centered, with a target at least 44 points high. Keep the two targets
equally distributed across the available width. Retain the native selected-icon
indicator and selected semantics; do not add an additional divider or custom tab
strip.

The total visible height is **44 + bottom safe inset**, not 44 including the
system gesture area. For example, a 34-point inset gives 78 points total, down
from 114. On a window with no bottom inset, the bar is 44 points high. Do not add
extra top/bottom visual padding or shrink the target below the app's existing
minimum. Native layout tests must verify the actual hit region and indicator
fit at this size.

Remove persistent text from both destinations, but keep the strings `Journals`
and `Favorites` in the destination model for screen-reader names and native
tooltips. Preserve keyboard activation, selected state, logical traversal order,
and sufficient icon/indicator contrast. Do not replace meaningful destination
labels with empty strings. Favorites retains its Star icon.

### Journals icon candidates

Use an existing MaterialIcons glyph through `Material_icon_catalog`, without a
new asset dependency or an AI-generated approximation. These names and code
points were verified in the installed Flutter `icons.dart` and rendered from the
installed MaterialIcons font for the review preview.

| Option | Material icon | Code point | Meaning and trade-off |
| --- | --- | --- | --- |
| A | `menu_book_outlined` | `0xf1c2` | An open notebook with visible lines. Communicates a journal or reading entries and is distinct from the Capture action. |
| B | `auto_stories_outlined` | `0xeeaf` | A book with a turning page. More expressive, with a less simple silhouette at small sizes. |
| C — selected | `view_day_outlined` | `0xf495` | A day/feed segment between horizontal lines. Matches timeline structure but can look like a layout selector. |
| D | `edit_note` | `0xf04f6` | Lines with a pencil. Emphasizes recording, but can be mistaken for the Capture/edit action. |

On 2026-09-08, the user selected **C — `view_day_outlined`**. Use this glyph
for Journals in the implementation.
The visible preview is a review artifact outside the Git worktree; the table
above is the persistent specification. Remove the obsolete Book catalog entry if
it has no remaining callers after the selected icon is adopted.

### Shared scroll trigger and destination isolation

Interpret down/up exactly as the existing FAB reducer does: scrolling toward
later content increases scroll pixels and hides the bar; scrolling toward earlier
content decreases pixels and shows it. This specifies content scroll direction,
not the finger's physical movement on the screen.

Reuse one public pure transition implementation for both root controls. Give each
destination its own trigger state so their accumulated travel does not mix.
Keep the state inside an existing compiled application module; do not add a dune
module entry. A small named submodule can expose the shared transition and public
state instead of duplicating the FAB's threshold logic. Update replaced callers
together, without legacy wrappers.

On Journals, one accepted transition drives both controls:

| Existing trigger state | Journals Capture FAB | NavigationBar |
| --- | --- | --- |
| Extended | Existing extended Capture affordance | Visible |
| Compact | Existing compact Capture icon | Hidden |

Favorites uses the same transition function for NavigationBar visibility and
continues to render no Capture affordance. This request does not make the FAB
fully disappear or change its threshold.

Preserve these exact trigger rules:

1. Initialize with navigation visible and accumulated travel zero.
2. Accumulate same-direction deltas; reversal replaces the accumulator with the
   new delta instead of requiring the user to undo previous travel.
3. Hide at accumulated positive travel `>= 24`; show at accumulated negative
   travel `<= -24`. Reset accumulated travel after either transition.
4. Reset to visible immediately at `pixels <= 0`. A zero delta away from the top
   does not change state.
5. Feed only the active root destination's relevant scroll samples. Do not let a
   detail route, composer, or inactive destination drive root navigation.

Adopted lifecycle behavior: initial launch, graph replacement, and selection
of a different destination show navigation and reset that destination's trigger
accumulator. Returning from a management/detail route also starts with navigation
visible. Reselecting the current destination preserves its state. These control
resets do not reset either list's scroll offset, loaded window, expansion state,
or draft. Empty, error-only, and non-scrollable roots keep navigation visible.

Native anchor restoration, `jumpTo`, list refreshes, viewport resizing, and the
navigation's own animation must not count as scroll intent. The current public
Scroll payload contains only pixels and delta; it does not identify origin.
Implementation must resolve that missing distinction at the existing native root
scroll owner, which already executes restoration, and pass accepted samples to
the public pure owner. Touch, trackpad, wheel scrolling, and user-initiated fling
continuation should follow the same threshold policy. Do not add a second observer
that independently drives the FAB while another drives navigation.

### Hide/show layout and motion

Hide the whole navigation control, not only its icons. The hidden bar must not
reserve its 44-point content height, paint an empty navigation surface, receive
pointer events, remain in keyboard traversal, or expose off-screen destination
actions to accessibility. Keep the operating system's bottom safe inset exactly
once for visible content and interactive controls.

Prefer built-in size/slide transitions around the existing built-in component,
using `Journal_visual_tokens.motion` for duration. The native scaffold remains the
owner of content/FAB positioning. With reduced motion, settle directly to the
requested geometry. Rapid direction changes reverse or replace the in-progress
transition without creating a queue of animations.

Keep the visible list anchored while its viewport changes height. Avoid feedback
where shrinking the bar changes scroll pixels and immediately toggles it back.
When navigation reappears, rows, Capture, and the composer must remain above the
system gesture area. Showing/dismissing the keyboard must not reveal a blank bar
or revive controls on Favorites.

### Expected implementation boundaries

- `app/journal_timeline_state.ml/.mli` or a named submodule of another existing
  compiled owner: shared public pure scroll trigger and its state.
- `app/application.ml/.mli`: destination-scoped trigger state, lifecycle resets,
  visibility projection, and one input path driving the FAB and navigation.
- `app/material_icon_catalog.ml/.mli`: selected Journals glyph and removal of its
  unused predecessor.
- `flutter/lib/journal_root_navigation.dart`: explicit minimum height, hidden
  labels, visibility animation, hit testing/semantics, and native scroll-origin
  handling where needed.
- Existing pure and native tests: verify each behavior at its actual owner.

No graph reads, worker protocol, protected `spec/` interfaces, dune files, or
bonsai_flutter OCaml source need changes. This proposal supersedes the previous
persistent-label requirement only for the visual presentation; destination names
and accessibility semantics remain meaningful.

## Decision

Implement the approved 44-point icon-only NavigationBar with Journals glyph
`view_day_outlined`. Adopt the proposed destination-isolated scroll state,
lifecycle resets, native input-origin filtering, and safe-area/motion policies.
The user's implementation request resolves the lifecycle recommendations in favor
of the behavior specified above.

## Alternatives considered

### Keep 64 or 80 points

Simpler to leave generous component defaults, but does not satisfy the requested
minimum height. A 44-point content region matches the app's existing target floor.

### Keep the full-height slot and only fade the icons

Avoids a viewport size change, but leaves the unused space that motivated the
request and can leave hidden controls interactive.

### Hide immediately on any delta

Responsive but prone to flicker and inconsistent with the requested FAB trigger.
Use the existing 24-point accumulated-travel mechanism.

### Share one trigger state across both destinations

Requires fewer fields, but scrolling Favorites changes the Journals FAB and leaks
accumulated travel across destination changes. Share the transition function,
with destination-scoped state.

### Use text-only pills or a custom bottom strip

Conflicts with the explicit icon-only request or duplicates an existing native
component. Keep the built-in NavigationBar.

## Acceptance criteria

- The visible navigation content is 44 points high, excluding the single required
  native bottom safe inset. Both destinations retain at least 44-point hit targets.
- Only icons are persistently visible; Journals/Favorites remain available as
  semantic names and tooltips. The chosen Journals glyph matches the user's choice.
- Journals and Favorites both hide navigation at the same positive 24-point
  threshold and reveal it at the same negative 24-point threshold as the FAB.
- Reversal, top reset, and zero delta match the existing FAB rules exactly.
  Journals FAB still switches between extended and compact forms.
- Trigger state is isolated between destinations. Launch, graph replacement, tab
  changes, and root return have the documented visible/reset behavior.
- List positions, windows, journal expansion, draft, and in-flight saves survive
  navigation visibility changes. Favorites remains read-only and Capture-free.
- Hidden navigation contributes no content height, hit targets, focus targets, or
  destination activation semantics. Safe-area handling is applied once.
- Native restoration/refresh/layout changes cannot trigger hide/show or create a
  feedback loop. User touch, wheel, and trackpad scrolling remain responsive.
- Native verification covers light/dark, high contrast, RTL, narrow/wide windows,
  enlarged text/tooltips, reduced motion, bottom insets, keyboard/composer,
  overscroll, fling, and rapid direction changes.
- All changes comply with `docs/ux-guidelines.md`; no dividers, compatibility
  layers, protected-interface edits, dune edits, or framework OCaml edits are added.

### Verification ownership

First reproduce threshold, reversal, tab isolation, and lifecycle behavior through
the production public pure owner's events, state, and effects. Retain existing FAB
tests; do not duplicate those regressions in native or transport tests.

Native height, hit testing, semantic removal, scroll-origin discrimination, and
viewport/animation feedback cannot execute in that pure reducer. Verify these
only at the narrowest existing native root/layout owner. Sending a pre-filtered
sample into the reducer does not prove that programmatic movement was filtered.

## Risks

- Hiding tab navigation makes destination switching require a reveal gesture.
  The proposed top/lifecycle/empty-state rules keep recovery predictable.
- A 44-point bar has less decorative spacing than Material's default; verify its
  actual indicator and target geometry instead of relying on absence of overflow.
- Losing visible labels reduces discoverability. Icon selection, tooltips, and
  screen-reader names matter more.
- Changing scaffold height can shift list/FAB geometry and produce synthetic
  scroll deltas. Native ownership and tests must prevent feedback and anchor loss.
- Public scroll payloads currently lack origin. Resolve that at the existing
  application native adapter instead of assuming every delta is user intent.

## Consequences

Navigation releases its 44-point content slot when hidden while the native bottom
safe inset remains reserved once. Users reveal destination switching by scrolling
up or returning to a root; the Capture FAB retains its compact/extended behavior.
The native root now identifies user intent before sending samples to OCaml.
Root input handling no longer consumes the unqualified renderer Scroll payload.

The shared trigger lives in the already compiled `Journal_timeline_state` module.
The replaced FAB-only entry points and unused Book catalog entry are removed.
No protected `spec/` interface, dune file, worker protocol, graph read, or
bonsai_flutter OCaml source is changed by this implementation.

## Questions

None. On 2026-09-08, the user selected **C — `view_day_outlined`** for Journals.
The minimum height, icon-only presentation, and shared FAB scroll trigger were
explicitly requested. Lifecycle and safe-area policies above are implementation
recommendations for review.

On 2026-09-08, after selecting the icon, the user requested transition to
proposed. All product questions are resolved. This transition changes the decision
document only. The later implementation request is completed below.


### Implementation outcome

- `Journal_timeline_state.Root_scroll_trigger` exposes the existing transition
  and public state. Its threshold, reversal, zero-delta, and top-reset tests are
  retained and updated to call the shared API.
- `Application.Root_navigation` owns separate Journals/Favorites triggers and
  public Scroll, Root_active, and Non_scrollable events. Tab changes, graph
  replacement, root return, empty/error content, and native non-scrollable
  observations reset the appropriate controls. Reselection preserves state.
  Draft and admitted-save tests exercise visibility changes and route coverage.
- The native root's scroll positions accept touch/trackpad offsets, wheel
  movement, and user-initiated ballistic continuation. Programmatic jumps,
  animateTo, restored anchors, viewport changes, and covered gestures are
  excluded. Touch overscroll at a clamped top still reports the top to the shared
  trigger. The root's existing renderer Scroll handler no longer drives controls.
- The built-in NavigationBar uses 44-point content height, hidden labels, and
  native selected indicators, tooltips, keyboard activation, and semantics.
  SizeTransition releases the content slot; hidden controls immediately leave
  hit testing, focus traversal, and accessibility. Reduced motion settles
  directly, and interrupted transitions use the latest visibility.
- The existing renderer supplies OCaml icons as font Text widgets. The navigation
  adapter fixes those glyphs at 24 points and applies the native IconTheme color,
  preventing text scaling and inherited line spacing from enlarging them.
  Tooltip text retains the user's text scaling. The selected Journals glyph is
  `0xf495`; Favorites retains `0xe5f9`.

### Verification

Pure RED verification failed at the missing shared Journals visibility transition
before implementation. Native RED verification observed the original 80/114-point
layout, absent accepted input, enlarged renderer glyphs, and covered-fling input.
The completed implementation passes the corresponding owner-level tests.

- `dune build @all` and `dune runtest` pass.
- `python3 tool/test_macos_regressions.py` passes all three registered suites.
- Installed `bonsai-flutter exec --profile=debug` with `flutter analyze --no-pub`
  reports no issues. `flutter test --no-pub` passes 152 tests; seven existing
  tests gated by `RUN_REAL_OCAML_GOLDEN` remain skipped.
- Native coverage includes actual OCaml Favorites frames across light/dark,
  high contrast, RTL, narrow/wide windows, enlarged text, exact glyph geometry
  and contrast; direct native coverage checks target/indicator fit, keyboard and
  selected semantics, hidden geometry and accessibility, reduced motion, bottom
  insets, composer/keyboard, independent offsets, refreshed anchors, touch,
  trackpad, wheel, fling, top overscroll, resizing, and rapid direction changes.
- Native screenshot review confirms the selected glyph and compact bar in a
  light 390-point layout and a dark high-contrast RTL 320-point layout at 3.2 text
  scale. These test artifacts are outside the Git worktree. No physical-device
  launch is claimed by this verification.
- Changed OCaml and Dart files pass formatting checks; `git diff --check` passes.
  Agent documents are validated with `spec-dev-tool check --all` at completion.


### Safe-area surface correction

On 2026-09-08, the user requested that the bottom safe area match the navigation
background. The native adapter now resolves one NavigationBar background color
and paints both the bar and its bottom inset with it throughout the visibility
animation. Once fully hidden, the inset remains reserved without painting a
navigation surface. This is a native paint correction; pure scroll ownership,
geometry, hit targets, and state are unchanged.
