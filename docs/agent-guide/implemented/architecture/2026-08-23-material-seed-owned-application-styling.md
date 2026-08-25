# Material Seed Owned Application Styling

## Problem

The application now declares a Material 3 theme from one seed in
`app/application.ml`, but the seed does not own most of the rendered Journal
appearance. `Ui.Theme.Color_scheme.from_seed` sends the seed, brightness,
dynamic variant, and contrast level to Flutter. The Flutter renderer then calls
`ColorScheme.fromSeed` and theme-aware Material widgets consume the resulting
semantic roles. Application-owned widgets instead receive concrete
`Ui.Style.Color.t` values and bypass that scheme.

The production styling corpus is split across several ownership boundaries:

- `app/application.ml` creates the application theme, Material action helper,
  route scaffolds, dialogs, Capture surfaces, Detail surfaces, graph picker,
  and several direct colors.
- `app/journal_visual_tokens.ml` and its interface own the Journal palette,
  interaction colors, typography metrics, spacing, hit regions, header,
  composer, row and preview geometry, motion, responsive row profiles, and
  virtualization extents.
- `app/journal_header.ml`, `app/journal_row.ml`, and
  `app/journal_timeline.ml` consume the custom palette for text, icons,
  backgrounds, dividers, press overlays, task-status rails, child connectors,
  and swipe-delete feedback.
- `flutter/lib/application.dart` owns the pre-runtime configuration failure and
  runtime-preparation states. `flutter/lib/application_host_adapter.dart` owns
  the Amplify authentication shell and currently supplies `ThemeData.light()`
  before the authenticated Bonsai application appears.
- iOS storyboards own a white launch surface independently of both Flutter and
  Bonsai. Application icons and raster test goldens are visual assets rather
  than theme configuration.
- `.bonsai-flutter/` is generated and is not an edit target, but its installed
  renderer is authoritative evidence for which logical nodes resolve Material
  theme roles at runtime.
- `docs/agent-guide/proposed/feature/2026-08-23-capture-fab-expanding-bottom-input.md`
  owns the separate product decision about replacing the resting persistent
  composer with a morphing FAB/input affordance. This styling decision must
  theme whichever Capture structure that feature selects without deciding its
  state, animation, focus, or Scaffold-slot ownership.

The custom token module contains 21 concrete colors in each of the light and
high-contrast-light palettes plus four interaction colors in each mode: 50
concrete palette entries. `neutral_badge` and `fab` have no production
consumer. Of the interaction record, only `pressed` has a production consumer;
`focused`, `disabled`, and `error` are tested but unused by the application.
`app/application.ml` additionally constructs the seed, two fixed dialog text
colors, and the same fixed Detail error color at two call sites. Consequently,
changing the seed from `rgb(24, 30, 52)` to the current working-tree value
`rgb(0, 38, 47)` changes Material components but leaves the Journal background,
header, rows, timestamps, status rails, modal scrims, Capture actions, and
delete action on their old fixed palette.

Several custom colors duplicate or override facilities that already resolve
the Material theme:

- Filled, Filled tonal, Outlined, Text, and Icon buttons are Material nodes, but
  Capture task and save actions add fixed-color decorated boxes around them.
- `Material.alert_dialog` owns its title and content defaults, but the shared
  discard/reset dialog helper supplies fixed title and content colors.
- Modal dialog and modal bottom-sheet routes have theme-colored default barriers,
  and the bottom-sheet route already supplies a Material `surface`, but the
  application sends a fixed scrim and paints a second fixed sheet surface.
- `Native_widget.Message_composer` already uses `primary`, `onPrimary`,
  `onSurface`, `onSurfaceVariant`, `surfaceContainerHighest`, and
  `outlineVariant`; the application still fixes its child icon color.
- `Material.divider` and `Material.list_tile` exist, while graph selection rows
  and all Journal dividers remain hand-built.

The current tests intentionally lock the parallel palette. In particular,
`test/journal_adaptive_test.ml`, `test/journal_semantics_test.ml`, and
`test/application_view_test.ml` assert exact ARGB values, and
`flutter/test/journal_runtime_golden_test.dart` searches for exact text,
divider, and four status-rail colors. Those tests prove the current fixed
palette rather than proving that semantic Material roles own styling.

This is not entirely a local cleanup. The installed framework exposes
`Theme.Color_scheme.t` as an opaque seed description. `Style.Color.t`,
`Style.Text_style`, `Style.Decoration`, generic icons, generic press overlays,
and `Native_widget.Swipe_action.action` accept concrete colors only. OCaml code
cannot name `surface`, `onSurfaceVariant`, `outlineVariant`, `error`, or another
derived role. The renderer computes those roles only after it receives the
logical frame. Therefore the application cannot strictly remove every
non-seed color while retaining every custom visual with the current public API.
Merely omitting generic text colors is also insufficient evidence: the current
theme decoder applies brightness-based black or white to its text theme rather
than deriving generic body/display text from `ColorScheme.onSurface`.

Existing implemented decisions also protect behavior that a styling migration
must not erase:

- the Journal header is a two-line, independently centered, adaptive header;
  the current `Material.app_bar` API cannot represent its layout directly;
- the current persistent MessageComposer retains its behavior unless the
  active Capture FAB exploration is separately resolved and proposed;
- top-level and child rows retain deterministic one-to-four-line extents,
  stable varied-sliver geometry, swipe ownership, exact semantics, and a
  leading status rail;
- Todo, Doing, Done, and Later rails are currently four distinguishable
  semantic families in normal and high-contrast presentation; and
- no rendered screen may contain more than three dividers.

The target is therefore an architecture decision: make the Material theme the
general UI color authority, adopt Material components where they match the
existing product role, retain only application-specific geometry and behavior,
and permit one explicitly bounded exception set for custom visuals that the
current framework cannot theme. It is not a promise to replace every layout
primitive with a Material component.

## Proposal

Adopt a seed-owned styling architecture with one production seed declaration
for the authenticated Bonsai application plus a bounded set of fixed colors
for the status rails and native destructive swipe action. Material semantic
roles should own all other general-purpose surfaces, content, outlines, state
layers, errors, and destructive presentation. `Journal_visual_tokens` should
cease to be a color theme and retain only application-specific non-color policy
such as geometry, motion, responsive profiles, deterministic row metrics, and
any typography metrics that cannot be expressed once through
`Ui.Theme.Typography`.

No implementation may begin while this document is exploring. A proposal must
also resolve the framework boundary for custom semantic colors.

### Establish one theme authority

Keep the application Material theme as the authenticated runtime theme owner.
Use `Ui.Theme.System`. Construct light, dark, high-contrast-light, and
high-contrast-dark theme data from the same seed and the same dynamic variant.
Do not create a second application palette, copy derived ARGB values into
OCaml, or use the seed itself as a replacement for semantic roles.

Move reusable Material typography and shape policy into
`Ui.Theme.Typography.material` and `Ui.Theme.Shape.create` where doing so lets
Material components and generic inherited text share one definition. Theme
typography entries should omit explicit colors so brightness and Material
ownership remain authoritative. Keep row-specific line metrics in
`Journal_visual_tokens` where virtualization needs exact application-known
extents; theme typography must not make Flutter text wrapping an implicit
source of sliver height.

The production-source invariant should be that `Ui.Style.Color.rgb` or
`Ui.Style.Color.argb` appears only at the selected seed declaration and in one
dedicated exception module. Tests may inspect the encoded seed and the bounded
exception contract but should not mirror every derived Material role as
hard-coded ARGB.

### Adopt existing Material components without style wrappers

Retain the existing Material Scaffolds, buttons, IconButtons, TextFields,
AlertDialogs, and progress indicator. Remove application decorations and child
colors that override their theme defaults:

- remove the Capture task button's fixed background and radius around its
  Outlined button;
- remove the Capture save button's fixed background, radius, and fixed child
  color around its Filled button;
- remove fixed title and content colors from the shared Material alert-dialog
  helper;
- omit modal `barrier_color` so both dialog and bottom-sheet routes use their
  theme-colored barrier;
- remove the inner fixed Capture sheet background because the route already
  owns the Material surface; and
- omit MessageComposer child icon colors so the native Plain and Filled button
  styles can supply `onSurface` and `onPrimary`.

Replace the graph picker's text-button rows with `Ui.Material.list_tile`. Keep
stable keys, click events, accessibility labels and hints, scrolling, width
constraints, and graph-selection behavior. This is the clearest current
`list_tile` consumer because each row is an immediate list action and does not
have the Journal row's variable-height, status, timestamp, expansion, or swipe
contracts.

Replace hand-drawn logical separators with `Ui.Material.divider` when its
rendered extent can be constrained to the existing physical-pixel geometry.
This includes the Capture header separator, Journal header divider, and
horizontal row/group separators. A Material Divider must not introduce its
default 16-pixel layout extent into a virtual row. The current Material API has
no VerticalDivider, so the child connector and bullet remain structural custom
decorations and need semantic outline colors from the prerequisite below. The
resulting screen must still render no more than three dividers.

Use Material `Card` only for a surface that already has card semantics. The
floating sync-error overlay is a candidate, but Card's margin, elevation, and
surface role must not silently replace an error/banner role. If the available
Card API cannot express the required banner semantics and positioning, keep
the structural overlay and resolve its colors through semantic theme roles
rather than retaining a fixed background.

Remove redundant root and row background decorations when the underlying
Scaffold surface is intended to show through. Keep a custom structural
container only where it owns clipping, shape, positioning, or a product-level
surface distinction; a container must not exist solely to repaint the same
fixed background over a theme-owned Scaffold.

### Retain custom components where Material is not equivalent

Do not convert the Journal header to the current one-title
`Ui.Material.app_bar`; doing so would lose the independently centered two-line
date context, adaptive height, account action geometry, or semantics. The
header may remain a custom layout over the Scaffold surface while its text,
icon, divider, and state colors become theme-owned.

Do not convert Journal rows to `Material.list_tile` merely because the API is
available. The current row coordinates deterministic one-to-four-line height,
timestamp suppression, collapsed child summaries, disclosure, a status rail,
RTL geometry, stable focus, varied-sliver extent, group boundaries, and native
swipe dismissal. The installed ListTile API does not expose the control needed
to preserve those contracts. Keep the custom row layout, remove its redundant
fixed background, and theme its remaining visual roles through the prerequisite
described below.

Retain `Native_widget.Swipe_action` because it owns maintained interaction
behavior that no current OCaml Material node replaces. Do not use this styling
decision to choose between the current persistent MessageComposer and the
active FAB/input exploration. If that feature later selects a Material FAB and
MessageComposer composition, both states must consume the same seed-owned
theme and must not restore fixed application colors. Do not add NavigationBar,
RadioGroup, Slider, RangeSlider, or Chip state without a product role.
Component availability alone is not a reason to change navigation or
task-editing behavior.

### Bound fixed colors for remaining custom visuals

Strict seed ownership would require a framework capability that is absent from
the installed public API: renderer-resolved semantic color references for
custom content. At minimum the remaining application would benefit from theme
roles for:

- Scaffold/surface content and variant content used by custom header, row,
  timestamp, supporting text, icons, connectors, and empty/loading views;
- outline/outline-variant separators;
- press state layers;
- error and on-error destructive swipe feedback; and
- the four agreed status-rail roles.

The application must not reproduce Flutter's Material Color Utilities
algorithm in OCaml. That would create a second scheme implementation whose
dynamic variant, contrast level, high-contrast behavior, and future Flutter
changes can drift. Applying opacity to inherited black or white is also not a
semantic substitute for `onSurfaceVariant` and does not provide the required
contrast contract.

Repository instructions prohibit modifying OCaml files in the
`bonsai_flutter` repository. This exploration selects the bounded-exception
option so the application styling change does not wait for a separately
delivered framework version. Generated sources under `.bonsai-flutter/` must
never be patched as a workaround.

The exception contract is deliberately narrow:

- four task-status rail roles: Todo, Doing, Done, and Later; and
- the background and foreground roles of the native destructive swipe action.

These roles must live together in one dedicated exception module rather than
preserving `Journal_visual_tokens.palette`. The module may select different
values for light, dark, high-contrast-light, and high-contrast-dark only when
contrast and distinguishability tests require it. It must expose named roles,
not a general-purpose color accessor, and no other component may reuse the
values merely because they are visually convenient. Adding another exception
role requires revisiting this decision.

All other fixed colors must be removed. Custom text and icons should omit
explicit colors and inherit the active theme. Separators should use Material
Divider. The child connector and bullet must retain their geometry without
adding another color exception, using a theme-inheriting primitive available
to the application. The custom pressed overlay must likewise be replaced by a
theme-owned interaction treatment or omitted; it is not part of the exception
set.

The current slate, blue, green, and purple values are not automatically
preserved by this exception decision. The selected fixed values must remain
visually distinguishable in light, dark, and both high-contrast variants and
must not reuse a destructive/error color to mean a successful or deferred task
state. Exact status names remain in semantics so color is never the only
carrier. If semantic roles become available later, the exception module should
be removed and the rails should migrate to stable scheme roles such as neutral
for Todo, primary for Doing, tertiary for Done, and secondary for Later.

### Define the host and platform boundary explicitly

The authenticated Bonsai theme is unavailable while Amplify configuration,
authentication, and runtime preparation are still in progress. The host
currently uses default Material applications or `ThemeData.light()` for those
surfaces. It cannot consume the OCaml seed without a new cross-boundary theme
configuration, and placing presentation data in the Logseq database worker
startup envelope would mix unrelated responsibilities.

The preferred narrow boundary is to treat pre-runtime and authentication UI as
neutral host infrastructure: use Material defaults and no additional RGB
literals, while the single branded seed owns the authenticated Bonsai
application. If the seed must also brand authentication and startup, that
requires a separate shared host/runtime theme configuration decision rather
than copying the RGB literal into Dart.

This exploration selects that narrow boundary. The single-seed requirement
applies only to the authenticated Bonsai application. Amplify authentication,
configuration failure, runtime preparation, and the iOS launch surface remain
neutral host/platform infrastructure and are not part of this styling change.
They should not gain a duplicated branded seed or a new host/runtime theme
protocol. A later request may reconsider those surfaces through a separate
decision.

The authenticated Bonsai application nevertheless follows system brightness.
The later implementation must remove the global iOS
`UIUserInterfaceStyle=Light` override so `Theme.System` can observe dark
appearance. This platform change does not bring host surfaces into the branded
seed scope: pre-runtime and authentication UI remain neutral and may continue
to use their own Material defaults.

iOS launch storyboard colors occur before Flutter and should use platform
semantic/system colors if they are included in scope. App icons, raster launch
art, and golden reference images are assets and should not be rewritten into a
runtime color-token system, but obsolete launch assets may be removed through
the normal generated-host/platform workflow if they have no maintained
consumer.

### Replace exact-color tests with ownership and accessibility tests

Retain structural, behavioral, semantics, hit-target, deterministic extent,
RTL, reduced-motion, and divider-count coverage. Replace application-palette
tests with tests that prove the new ownership boundary:

- the encoded application theme carries the one expected seed and selected
  light, dark, and high-contrast variants;
- Material nodes are used at accepted call sites and are not wrapped in
  fixed-color decorations;
- modal route barrier colors are omitted and the Capture sheet does not paint a
  second surface;
- graph rows are Material ListTiles with stable keys and correct actions;
- no production OCaml source constructs concrete colors outside the one seed
  and the dedicated, allow-listed exception module;
- `Journal_visual_tokens` exposes no general UI palette or unused interaction
  record;
- runtime Flutter tests resolve representative components through the actual
  `ColorScheme.fromSeed` theme;
- status, destructive, text, and surface roles satisfy contrast and status
  distinguishability in every supported theme variant; and
- runtime goldens verify the visual result without copying the former fixed
  palette into multiple test files.

Source-boundary assertions that intentionally require `Ui.Theme.Light`, fixed
custom surfaces, or obsolete palette symbols must be updated. Historical
implemented documents remain unchanged as evidence of the decisions they
delivered.

## Decision

Use the authenticated Bonsai application's one `rgb(0, 38, 47)` seed as the
general color authority. The application now publishes light, dark,
high-contrast-light, and high-contrast-dark Material theme data in
`Ui.Theme.System` mode. Theme typography and shape data contain no explicit
colors, so Material components and generic text or icons inherit the selected
scheme.

Remove the general-purpose palette and interaction records from
`Journal_visual_tokens`. Keep one nested `Color_exceptions` module whose only
fixed roles are Todo, Doing, Done, and Later status rails plus the background
and foreground of the native destructive swipe action. The same six accepted
colors meet the runtime contrast and distinguishability thresholds in all four
presentations, so the implementation does not duplicate them per variant.

Use Material ListTile for graph selection, Material Card for the floating sync
error, and Material Divider for the retained header and Capture separators.
Remove the repeated row and group separators instead of reproducing them across
the virtual timeline; the rendered Journal screen consequently contains one
divider and remains below the three-divider limit. Keep the child connector and
bullet as theme-inheriting structural primitives, and keep the custom Journal
header, variable-height rows, status rails, and native swipe interaction.

Remove fixed colors from buttons, dialogs, modal barriers, Capture surfaces,
rows, headers, text, icons, errors, and press overlays. Remove the iOS forced
Light appearance. Pre-runtime, authentication, and launch surfaces remain
neutral host infrastructure and do not receive a copy of the authenticated
application seed. The separate Capture FAB decision continues to own replacement
of the persistent MessageComposer and its Scaffold slot.

## Alternatives considered

### Keep `Journal_visual_tokens` as the application color theme

This preserves exact current pixels and requires only updating its values when
the seed changes. It leaves two independent color authorities, continues to
override Material state and accessibility behavior, and makes the seed
misleading. It does not meet the target.

### Generate a second concrete palette from the seed in OCaml

Reimplementing Material Color Utilities or checking generated ARGB into OCaml
would make custom widgets appear coordinated initially. It would duplicate the
Flutter algorithm and must independently track dynamic variants, contrast,
brightness, and framework upgrades. This relocates rather than removes the
parallel theme and is not acceptable.

### Use the seed color directly for every custom visual

The seed is an input to a tonal scheme, not a semantic surface, content, error,
or outline role. Reusing it for backgrounds, text, state layers, and delete
feedback would lose contrast and semantics. It also would not make the UI a
Material ColorScheme consumer.

### Use inherited color plus opacity for secondary roles

This can remove RGB literals with the current generic widget API, but it does
not select `onSurfaceVariant`, `outlineVariant`, or contrast-adjusted high-
contrast roles. Opacity also blends through intermediate surfaces and makes
contrast dependent on composition. It is not the target architecture.

### Convert every custom layout to a Material component

Replacing the two-line header, variable-height journal rows, status rails, or
swipe action only to gain theme access would discard maintained product
behavior. The separate Capture FAB exploration owns any MessageComposer
replacement. Material components should replace equivalent roles, not force
unrelated interaction or geometry changes.

### Keep status and destructive colors as bounded exceptions

This is implementable in the current repository and removes the parallel
general-purpose palette. It does not meet a literal one-RGB-only invariant, but
it is the selected bounded compromise for the current framework. The exception
roles are named explicitly above, and all unused/general palette fields must
still be removed.

### Duplicate the seed in Dart for authentication and OCaml for the runtime

This brands more of the startup experience but creates two authoritative
literals and permits host and runtime themes to diverge. Adding the seed to the
database worker configuration would avoid literal duplication at the cost of
polluting a storage/sync contract with presentation state. Neither is a clean
single-source design.

### Keep the application fixed to Light mode

This would reduce the supported presentation matrix and preserve the current
iOS appearance. It was not selected: the application should use
`Theme.System`, generate high-contrast-dark data from the same seed, and remove
the iOS `UIUserInterfaceStyle=Light` override.

## Acceptance criteria

- The accepted scope defines exactly one production seed declaration and no
  second application palette. Concrete RGB/ARGB values outside that declaration
  exist only in the dedicated exception module for four status rails and the
  destructive swipe background/foreground.
- `Journal_visual_tokens` owns only non-color application policy. Unused
  `neutral_badge`, `fab`, `focused`, `disabled`, and `error` tokens and every
  obsolete palette accessor disappear rather than remaining as compatibility
  paths.
- Existing Scaffolds, buttons, IconButtons, TextFields, AlertDialogs, progress
  indicators, MessageComposer, and modal routes consume theme defaults without
  application fixed-color wrappers.
- Graph picker actions use Material ListTile while retaining stable identity,
  scrolling, accessibility, selection, and refresh behavior.
- Material Divider owns each retained equivalent separator without changing
  virtual row extents or child geometry. Repeated row and group separators are
  removed, every screen remains below three dividers, and the non-equivalent
  connector and bullet decorations are explicitly classified.
- The Journal header, row, status rail, and SwipeAction retain their implemented
  product and interaction contracts. The active Capture FAB exploration owns
  any change to MessageComposer/FAB structure. No NavigationBar, RadioGroup,
  Slider, RangeSlider, or Chip behavior is introduced without a matching
  product requirement.
- Root, row, and Capture sheet surfaces do not repaint fixed colors over an
  already theme-owned Material surface. Modal barriers use their theme default.
- Every remaining custom visual color is inherited from the active theme or is
  one of the six named exception roles. The exception module is not reusable as
  a general palette, and no generated `.bonsai-flutter/` file is edited.
- Todo, Doing, Done, and Later remain accessible without color, and their
  accepted visual roles remain distinguishable against the active surface in
  normal and high-contrast presentation.
- The application uses `Ui.Theme.System` and supplies light, dark,
  high-contrast-light, and high-contrast-dark data from the one seed. iOS no
  longer forces `UIUserInterfaceStyle=Light`, and no mixed dark Material
  controls and fixed light custom surfaces remain.
- Host configuration failure, authentication, runtime preparation, and the iOS
  launch surface remain out-of-scope neutral infrastructure. They introduce no
  duplicated branded seed or new host/runtime theme protocol.
- Exact former palette assertions are replaced by theme ownership, semantic
  role, accessibility contrast, component-kind, and runtime rendering tests.
  Existing semantics, stable sliver geometry, pagination, scroll anchoring,
  swipe/delete, Capture, Detail, graph selection, RTL, text scale, reduced
  motion, high contrast, and platform startup behavior remain covered.
- `spec-dev-tool check --all`, `dune runtest`, `bonsai-flutter sync-host
  --check`, Flutter analysis and tests through `bonsai-flutter exec`, the macOS
  debug build, and the unsigned iOS debug build succeed for the eventual
  implementation.

## Risks

- Material defaults will change some colors, typography, padding, radii,
  elevation, and disabled/pressed states. Exact visual fidelity to the current
  palette is intentionally not guaranteed.
- Material ListTile and Divider have intrinsic layout policy. Incorrectly
  adopting them could change graph-row density or inject default divider extent
  into the varied sliver.
- Removing explicit row and header backgrounds exposes the Scaffold surface.
  Overlay, clipping, swipe translation, and modal transitions must not reveal
  an unintended intermediate color.
- A seed-generated tonal scheme does not guarantee that four arbitrary roles
  remain perceptually distinct under every dynamic variant or contrast level.
  Status-role selection needs runtime evidence.
- The bounded exceptions will not automatically track future seed, dynamic-
  variant, or Flutter Material changes. Runtime contrast tests across all four
  presentation variants are required until a future framework capability lets
  the application remove the exception module.
- System mode expands the supported matrix to dark and high-contrast-dark and
  changes iOS behavior. Every custom visual and runtime test must cover the
  expanded matrix so a light-only surface cannot survive unnoticed.
- Pre-runtime Flutter and platform surfaces cannot inherit an OCaml-owned theme.
  Broadening the single-seed boundary can introduce an undesirable cross-layer
  configuration contract.
- Tests that assert semantic role ownership can become coupled to Flutter SDK
  behavior if they record every derived ARGB. Runtime checks should target
  contrast, distinction, and component behavior rather than duplicate the
  complete scheme.

## Consequences

- Changing the single seed now changes the authenticated application's Material
  surfaces, text, controls, dividers, modal barriers, and error roles together.
- System dark and high-contrast appearance are supported on iOS and macOS. The
  host authentication and startup surfaces remain separately neutral.
- Fixed application colors are limited to six named interaction-specific roles.
  Adding another fixed role requires a new decision; a future framework semantic
  color API can remove the exception module entirely.
- Repeated timeline separators are gone. Stable row extents, scroll anchoring,
  swipe ownership, child geometry, and semantics remain unchanged, while the
  Journal screen renders only one divider in its resting state.
- Graph rows use Material ListTile and the sync error uses Material Card, so their
  disabled, pressed, surface, and content presentation track Material theme
  behavior rather than application wrappers.
- Golden images intentionally change with Material's derived scheme. Tests assert
  seed ownership, semantic contrast, component roles, and bounded exception
  colors instead of preserving the former parallel palette.

## Questions

- None. The scope, system theme variants, status-role freedom, and bounded
  fixed-color exception policy have been selected during exploration.
