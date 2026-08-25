# Material Icons Render Incorrect Glyphs

## Problem

The Release application renders an incorrect Capture icon on both macOS and
iOS. No incorrect Account, Refresh, Delete, or disclosure icon has been
observed, so this decision does not claim or attempt to repair a system-wide
icon failure. The observed Capture failure looks similar to the runtime
Material icon tree-shaking failure addressed in `bonsai_flutter`, but the
checked repository and Release artifacts rule out that explanation.

`Bonsai_flutter_ui.Widget.icon` sends a numeric code point and optional font
family through a runtime protocol frame. The Flutter renderer constructs a
`Text` from `String.fromCharCode` with a `TextStyle`; it does not contain a
static Dart `IconData` reference. Flutter's icon tree shaker therefore cannot
discover these glyphs from the Dart program.

That limitation was addressed in `bonsai_flutter` commit
`6f52ea79539ed0e115bac5991ab2db8f176dc88d`: Profile and Release `build`
commands add `--no-tree-shake-icons`. Follow-up commit
`fa3015111e49ef7eafeba76e90edcc5ee0ae66cf` removed that build-only argument
from `run` commands because `flutter run` does not expose the option. This does
not reintroduce tree shaking: Flutter 3.44.8 only enables icon tree shaking when
the command parser contains the option, and the `run` parser does not contain
it. Both the old application pin `9b345b90fea476391d19092675abd665655e586a`
and the current worktree pin `d182690aeaa82ad0a972756205c62e3b598e3c24`
contain both framework commits.

The existing artifacts provide additional negative evidence against tree
shaking. The macOS and iOS Release bundles each contain a 1,645,184-byte
`MaterialIcons-Regular.otf`. The iOS Release copy has the same SHA-256 as the
Flutter SDK cache:
`d9865b671a09d683d13a863089d8825e0f61a37696ce5d7d448bc8023aa62453`.
These are complete fonts, not the small subset that a successful icon tree
shake would produce. Debug and Profile artifacts were also inspected and
contain the same complete font, but they are supporting evidence rather than
part of the reported failure scope.

The failure is deterministic in the current application source. The new
Capture floating action button uses `0xe145` for an Add icon. In the active
Flutter 3.44.8 SDK, `0xe145` is `Icons.cast_connected`; `Icons.add` is
`0xe047`.
Because both Apple platforms bundle the same Flutter Material font and consume
the same OCaml frame, the same wrong glyph appears in both Release apps. The
other checked literals resolve to their intended current SDK names:

| Application role | Code point | Flutter 3.44.8 icon |
| --- | ---: | --- |
| Account | `0xe043` | `account_circle` |
| Capture submit | `0xe0a0` | `arrow_upward` |
| Capture FAB | `0xe145` | `cast_connected` (incorrect; intended `add`) |
| Collapsed disclosure, RTL | `0xe15e` | `chevron_left` |
| Collapsed disclosure, LTR | `0xe15f` | `chevron_right` |
| Child bullet | `0xe163` | `circle` |
| Delete | `0xe1b9` | `delete` |
| Expanded disclosure | `0xe246` | `expand_more` |
| Refresh | `0xe514` | `refresh` |

This is the same design weakness that required the application-level icon
repair in commit `f86546fe6ca9ec6f86084bd81c742214235e3d79`: source files embed raw
numeric values whose meaning changes with the Flutter SDK icon font. That
commit replaced obsolete Account circle and Refresh values with the values
from the active SDK, but no named application contract prevents a later feature
from copying an obsolete value back into a new call site. Tests currently
verify widget type, font family, and sometimes the same numeric value; they do
not independently verify that a product role resolves to the intended Flutter
glyph. The new FAB coverage checks its test identity but not its glyph identity.

The Release-only observation does not make Release compilation the cause. The
wrong `0xe145` value is present in the shared application frame in every build
mode; Release is simply the build that was inspected by the reporter. The
complete Release font faithfully renders the requested but unintended Cast
connected glyph.

## Decision

Treat this as an application icon identity bug, not a tree-shaking bug. Replace
the Capture FAB's obsolete raw Add value with the current SDK Add value and
introduce one application-owned Material icon catalog. Call sites select named
product roles rather than numeric code points. A framework-level named icon API
is outside this bugfix; it may be considered in a separate `bonsai_flutter`
decision if multiple applications need the same contract.

`app/material_icon_catalog.ml` and `app/material_icon_catalog.mli` own:

- a closed `t` variant for the roles used by this application: Account circle,
  Add, Arrow upward, Chevron left, Chevron right, Circle, Delete, Expand more,
  and Refresh;
- the `MaterialIcons` font family;
- the Flutter 3.44.8 code point for each variant; and
- one widget constructor that accepts the optional key, size, and color needed
  by current call sites and returns a `Bonsai_flutter_ui.Widget.icon`.

`app/application.ml`, `app/journal_header.ml`, `app/journal_row.ml`, and
`app/journal_timeline.ml` use the catalog. The Capture FAB selects `Add`, and
the Capture submit action selects `Arrow_upward`. Those consumers contain no
direct Material font-family strings or Material code-point literals. There is
no compatibility helper or preserved raw Material icon construction path.

`test/source_boundary_test.ml` ensures that only the catalog may contain the
`MaterialIcons` family or Material code-point literals. The OCaml view tests
assert the named roles selected by Account, Capture, disclosure, child bullet,
Delete, and Refresh call sites. `flutter/test/journal_runtime_golden_test.dart`
inspects the real runtime Capture widgets and compares the rendered character against
`Icons.add.codePoint`; this keeps the SDK-owned expectation independent from
the OCaml catalog literal. `tool/verify_material_icons_font.sh` compares each
Release bundle font's size and SHA-256 with the active Flutter SDK font and
rejects missing, subset, or mismatched copies. The build policy is unchanged.

## Implementation evidence

The real-runtime Flutter test failed before the change with the Capture FAB
rendering `U+E145` instead of `Icons.add` at `U+E047`. It passes after the
catalog migration and also verifies the Capture submit action against
`Icons.arrow_upward`.

All relevant OCaml tests, Flutter tests, `flutter analyze`, and
`bonsai-flutter sync-host --check` pass. macOS and unsigned iOS Profile and
Release builds complete successfully. Both final Release bundles contain a
1,645,184-byte `MaterialIcons-Regular.otf` with SHA-256
`d9865b671a09d683d13a863089d8825e0f61a37696ce5d7d448bc8023aa62453`,
matching the active Flutter 3.44.8 SDK font.

## Alternatives considered

### Disable icon tree shaking in `flutter/pubspec.yaml`

Flutter exposes icon tree shaking as a build option, not a pubspec policy. The
framework tool already owns the required Profile/Release build flag, and all
checked artifacts contain the complete font. Adding generated-host state would
duplicate framework policy without fixing the confirmed wrong code point.

### Add static Dart `Icons.*` references for the current icon set

This would make the current set visible to the tree shaker, but the runtime
protocol can supply code points that the Dart host does not know in advance.
Every new icon would require synchronized Dart and OCaml edits, and missing one
would silently reproduce the same release-only failure.

### Keep raw code points and correct only `0xe145`

This is the smallest immediate repair, but it preserves the mechanism that
already allowed obsolete Account, Refresh, and now Add values to enter the
application. It also leaves tests coupled to the same mistaken literals as the
implementation.

### Replace all Material glyphs with text or custom vector assets

This would remove the Material font dependency, but it expands a one-glyph
confirmed defect into a visual-system replacement. There is no evidence yet
that the maintained Flutter Material font cannot satisfy the product roles.

## Acceptance criteria

- The macOS and iOS Release applications render the Capture FAB as Add and
  Capture submit as Arrow upward.
- Existing Account, Refresh, Delete, disclosure, and child-bullet roles retain
  their currently intended glyphs; task-status rails remain unchanged.
- The failing artifact's `MaterialIcons-Regular.otf` size and SHA-256 are
  recorded and compared with the active Flutter SDK cache.
- The Capture FAB renders Add rather than Cast connected.
- Application Material icon call sites select named roles from one catalog and
  do not embed raw Material code points or font-family strings.
- Catalog tests validate each named role against an independent mapping derived
  from the selected Flutter SDK, rather than restating implementation literals.
- A macOS and an iOS Release runtime verification cover the Capture icon roles
  using the real bundled Material font.
- Release artifact verification rejects a subset or mismatched Material font
  before either Apple app bundle is accepted.
- `bonsai-flutter sync-host --check`, relevant OCaml tests, Flutter tests,
  macOS Profile/Release builds, and an unsigned iOS Profile/Release build pass.

## Consequences

- A named application catalog still depends on the selected Flutter SDK's
  Material font revision; SDK upgrades must update and verify the catalog as an
  explicit compatibility boundary.
- Artifact verification adds build time and must distinguish a valid full font
  revision change from accidental subsetting or a stale cached font.
- Golden images can approve an incorrect glyph when regenerated mechanically.
  Semantic role assertions and SDK mapping checks remain necessary even with
  visual coverage.
- A future Flutter SDK may assign different code points. The catalog and its
  SDK-backed Flutter test must be updated together rather than allowing a
  silent glyph change.

## Questions

- None. The observed scope is the Capture icons in macOS and iOS Release apps,
  and the durable fix is an application-owned named icon catalog.
