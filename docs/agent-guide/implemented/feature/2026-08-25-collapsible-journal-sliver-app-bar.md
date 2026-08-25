# Collapsible Journal Sliver App Bar

## Problem

The Journal route currently renders `Journal_header.view` as a fixed box above
the timeline viewport. The header permanently consumes its 48-point content
height, eight points of vertical padding, the device top safe-area inset, and
one physical-pixel divider while the user scrolls journal entries. Its custom
`SafeArea`, `Stack`, and column composition preserves an independently centered
two-line date context, but it cannot collapse because it does not participate
in the timeline's scroll geometry.

The timeline owns its own `Ui.Widget.Scroll_view.vertical`, so placing a
collapsible header in `application.ml` would create nested or disconnected
scroll owners. The route instead needs one custom scroll view containing both
the header and the virtual varied-extent timeline. Loading, empty, error, and
populated states must use that same structure so the top bar does not change
its safe-area, account-action, or scroll behavior when data state changes.

The installed `bonsai_flutter` API now exposes `Ui.Widget.Sliver.app_bar` with
pinned, expanded, collapsed, toolbar, title, flexible-space, bottom, leading,
and action slots. This is a different and more capable contract than the
one-title `Ui.Material.app_bar` rejected by earlier styling decisions. The app
can therefore adopt a real Flutter `SliverAppBar` without changing the
framework, generated host packages, or renderer protocol.

## Decision

Replace the fixed Journal header with one pinned, non-floating
`Ui.Widget.Sliver.app_bar`. At text scale 1.0, use a 96-point expanded content
extent and a 56-point collapsed toolbar extent. Flutter continues to own and
add the device top inset. The app-owned extents additionally account for the
one-physical-pixel divider. Do not set application colors: the app bar, text,
icon, and divider continue to inherit the Material theme. Keep elevation at
zero and do not add a new surface decoration.

Runtime-first implementation found that the bundled Flutter frame decoder
declares `preferred_size` as node kind 39 but omits kind 39 from its node-kind
decode dispatch. Supplying the app bar `bottom` therefore makes every frame
fail with `Unknown node kind 39`. The generated host and `bonsai_flutter`
sources are protected by this decision, so the divider is instead the bottom
positioned child of `flexible_space`. The explicit collapsed and expanded
heights include its physical-pixel thickness. At DPR 1 and text scale 1 this
means `toolbar_height = 56`, `collapsed_height = 57`, and
`expanded_height = 97`; with a 47-point Flutter top inset, the rendered
collapsed and expanded extents are 104 and 144 points. This preserves the
selected visual geometry without modifying the framework or generated host.

The app bar has the following behavior:

- `pinned = true`, so the collapsed toolbar and Account menu remain reachable;
- `floating = false`, `snap = false`, and `stretch = false`, so reversing scroll
  does not reveal or expand the header independently of scroll position;
- `automatically_imply_leading = false`, because the Journal root cannot pop;
- `center_title = true`, with a leading placeholder balancing the trailing
  Account action where the public toolbar geometry permits it;
- the context title, such as `Today`, remains visible in both states;
- the context subtitle occupies flexible space below the toolbar title and is
  clipped away as the app bar reaches its collapsed extent; and
- the date context retains one truthful combined semantics label while the
  Account menu remains one enabled button with its current label, hint, and
  tap action.

The user confirmed on 2026-08-25 that standard `SliverAppBar` centered-title
geometry is acceptable, including minor pixel-level differences from the old
custom `Stack`; that expanded and collapsed heights should use separate
large-text formulas while retaining 96 and 56 as their scale-1 minimums; and
that macOS and mobile should use the same pinned collapsing behavior.

Replace `Journal_header.view` with a sliver-producing interface and remove the
obsolete fixed-header container, manual top `SafeArea`, header `Stack`, and
header surface path. Do not retain a box-header fallback.

Change the Journal timeline boundary so it supplies content slivers rather
than constructing a scroll view. The populated state supplies the existing
keyed `Ui.Widget.Sliver.varied_extent`; loading, empty, and error states supply
box or fill slivers. `application.ml` becomes the only Journal scroll owner and
constructs one keyed `Ui.Widget.Scroll_view.vertical` with the app bar first
and the state-specific content sliver second. Preserve the existing virtual
window, sparse extent overrides, overscan, stable item keys, visible-range
events, pagination behavior, row scroll anchoring, body overlays, centered
maximum content width, and Scaffold `bottom_navigation_bar`.

Derive expanded and collapsed extents from text scale rather than allowing
large text to overflow fixed values. The scale-1 baselines remain 96 and 56.
The collapsed extent must fit one scaled title line and the 44-point Account
target; the expanded extent must additionally fit the scaled subtitle and
spacing. Set the toolbar and collapsed content extent to
`max 56 (scaled title line height + 16)`. Set the expanded content extent to
`max 96 (scaled title line height + scaled subtitle line height + 24)`.
Add one physical-pixel divider thickness to both configured app-bar extents.
Device-pixel ratio affects only that thickness. Flutter adds the device top
inset according to native `SliverAppBar` geometry; the application must not
add a second safe area.

Implement the change test-first. OCaml view tests should assert one vertical
scroll view, an app-bar sliver before the content sliver, exact behavior flags,
adaptive extents, slot ownership, theme-owned presentation, and all route data
states. Semantics tests should continue to exercise the Account action and the
combined date label. Runtime Flutter tests should verify the actual
`SliverAppBar` expanded, collapsed, pinned, safe-area, clipping, divider, and
narrow/large-text behavior. Existing timeline, pagination, scroll anchoring,
golden, and Capture tests remain regression coverage.

Do not modify Dune files, OCaml files under `spec/`, generated files under
`.bonsai-flutter`, or any OCaml file in the `bonsai_flutter` repository. Remove
the obsolete custom header layout and its tests instead of preserving a
compatibility path.

## Alternatives considered

### Keep the fixed custom header

This preserves the current geometry with minimal risk, but the header remains
outside scroll geometry and permanently consumes vertical space. It does not
provide the selected expanded-to-collapsed behavior.

### Use a fixed-height SliverAppBar

A pinned app bar with equal 56-point expanded and collapsed extents would
unify scroll ownership, but it would be behaviorally equivalent to the current
fixed header and would discard the selected two-state presentation.

### Hide the complete header with floating and snap

`floating = true`, `snap = true`, and `pinned = false` would maximize reading
space, but it would temporarily remove the Account menu and make desktop
scroll behavior more volatile. The selected scheme keeps the collapsed bar
continuously available.

### Use platform-specific header behavior

Collapsing on mobile while retaining a fixed bar on macOS could optimize each
platform independently, but it would create two interaction contracts and a
larger accessibility and runtime matrix. A single cross-platform contract is
simpler unless product direction explicitly requires desktop divergence.

### Add a second scroll view around the existing timeline

Nested vertical scroll views would split offset, gesture, visible-range, and
pagination ownership. A `SliverAppBar` only coordinates with slivers in its own
custom scroll view, so nesting cannot produce the required behavior reliably.

### Extend bonsai_flutter for collapse-progress animation

Exposing shrink progress, `FlexibleSpaceBar`, `scrolledUnderElevation`, title
spacing, or leading-width controls would allow finer animation and geometry.
The selected interaction can use the existing public slots. Framework work is
out of scope unless runtime evidence shows that those slots cannot meet the
accepted centering or accessibility requirements.

## Acceptance criteria

- The Journal route contains exactly one vertical custom scroll view in
  loading, empty, error, and populated states.
- That scroll view contains one `Ui.Widget.Sliver.app_bar` before exactly one
  state-specific content sliver; the old fixed `Journal_header.view` path and
  nested timeline scroll view no longer exist.
- At text scale 1.0 and DPR 1, the bar has a 97-point configured expanded
  extent, a 57-point configured collapsed extent, and a 56-point toolbar; the
  extra point is the divider and Flutter separately adds the top system inset.
- The app bar is pinned, non-floating, non-snapping, non-stretching, centered,
  zero-elevation, and does not imply a leading navigation action.
- `Today` or the selected context title remains visible when collapsed; the
  subtitle is visible when expanded and visually absent when fully collapsed.
- The Account menu remains visible, focusable, enabled, and tappable in both
  states, with its existing semantic label and hint.
- The date context exposes one truthful label combining title and subtitle and
  does not expose a false button or navigation action.
- Light, dark, high-contrast light, and high-contrast dark modes use
  theme-owned surface, text, icon, divider, and interaction colors.
- Narrow width, RTL, and supported large text scales do not clip the title,
  overlap the Account action, or place a tap target below 44 points.
- The existing one-physical-pixel divider remains visible and no rendered
  screen exceeds the project limit of three dividers.
- Timeline item keys, sparse extents, visible ranges, pagination requests,
  scroll anchoring, swipe actions, body overlays, and Capture bottom-navigation
  layout retain their current observable behavior.
- Focused OCaml view and semantics tests fail before implementation and pass
  afterward; the complete OCaml suite, Flutter analysis and tests, runtime
  golden matrix, host sync check, and macOS Debug build pass.
- No Dune file, protected `spec/` OCaml file, generated `.bonsai-flutter`
  source, or `bonsai_flutter` repository source is modified.

## Consequences

- The Journal has one stable custom-scroll owner across loading, empty, error,
  and populated states, so the pinned header and virtual timeline share one
  offset and gesture contract.
- The title and Account action remain available in the collapsed toolbar,
  while the subtitle is clipped with the shrinking flexible space.
- Large text uses separate adaptive toolbar and expanded-content formulas;
  device-pixel ratio changes only the divider contribution.
- The divider is visually and geometrically equivalent to an app-bar bottom,
  but `SliverAppBar.bottom` remains unset until the bundled decoder accepts
  `preferred_size` node kind 39. Runtime tests lock this intentional shape.
- No generated host, Dune file, protected spec, or `bonsai_flutter` source is
  changed.

## Risks

- Moving the varied-extent list behind a preceding sliver changes physical
  scroll offsets. Tests must prove that logical visible ranges, initial
  anchoring, pagination, and row identity remain stable.
- The public `Sliver.app_bar` binding does not expose every Flutter toolbar
  geometry option. Standard centered-title layout may differ slightly from the
  current full-width custom `Stack`, especially with asymmetric actions or
  large text.
- An arbitrary flexible-space child receives changing constraints but no
  explicit collapse fraction in OCaml. The subtitle can be positioned and
  clipped, but custom opacity or scale interpolation is not available without
  framework work.
- Explicit collapsed and expanded extents interact with the native top inset
  and flexible-space divider. Runtime tests distinguish app-owned logical
  height from Flutter-owned safe-area height to prevent double insets.
- A visually clipped subtitle can still produce duplicate or stale semantics
  if semantics ownership is split between title and flexible space. One parent
  date label and focused renderer tests are required.
- Rebuilding the scroll-view boundary may reset an existing viewport if its
  key changes. The final design must use stable identity and must not recreate
  the scroll view merely because loading or account availability changes.
