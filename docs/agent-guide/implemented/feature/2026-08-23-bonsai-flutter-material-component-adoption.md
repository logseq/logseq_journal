# Bonsai Flutter Material Component Adoption

## Problem

The active OPAM switch installs `bonsai_flutter`, `bonsai_flutter_test`, and
`bonsai_flutter_tool` from SDK repository commit
`9b345b90fea476391d19092675abd665655e586a`. That repository includes the
framework component and application-theme work from
`4f7d6134d0d5f3850d78aa6fe8eea8f6f2654762`, but the application manifests,
lockfiles, and source-boundary test
still select the older SDK repository commit
`a6bd9aa9906c0e49f0cc365e5ba33270e89655e6`.

This is not only a dependency metadata mismatch. The updated framework removes
obsolete public paths and changes application ownership:

- `Material.dialog` no longer exists. `Material.alert_dialog` now owns the
  visual surface while `Navigation.Modal_dialog` owns barrier, focus, safe-area,
  transition, restoration, and back-navigation policy.
- Every application component must return `App.View.t`, pairing an explicit
  `Theme.application` with the logical root widget.
- `BonsaiFlutterRoot` owns the single live application `MaterialApp`; a custom
  host must not wrap the root in another `MaterialApp`.
- `page_presentation` now includes `Modal_dialog`, so exhaustive application
  and test matches must account for it.

The mismatch is already observable. `dune build @all` stops at the first of
three `Ui.Material.dialog` construction sites, and
`test/application_view_test.ml` fails exhaustive matching because it handles
only standard pages and modal bottom sheets. `bonsai-flutter sync-host --check`
also reports that `flutter/lib/main.dart` is out of date.

The application additionally maintains hand-built versions of facilities that
the new framework now owns:

- four dialog flows are represented by three generic dialog construction
  sites and application-local overlays;
- delete success, Undo, and delete failure use an application-drawn snackbar
  with manual positioning and lifetime state;
- the persistent Capture composer is a positioned body overlay, requiring a
  synthetic `Bottom_clearance` virtual-list slot and duplicated geometry; and
- one `action_target` helper renders twenty-eight call sites as text buttons,
  even when the actions are primary, secondary, or confirmatory.

Adopting every newly available Material component would not be justified.
There are no current product roles for a floating action button, bottom
navigation bar, radio group, slider, range slider, or general chip group, and
the current route hierarchy is not a set of peer destinations. The decision
therefore needs to distinguish required API migration, evidence-backed
component adoption, and components that remain deliberately unused.

## Proposal

Upgrade the repository-owned dependency metadata to
`9b345b90fea476391d19092675abd665655e586a`, migrate to the new application and
dialog ownership contracts, and adopt only the new Material component APIs that
replace an existing application-owned facility with the same product role.
Remove each obsolete path instead of retaining compatibility helpers or
parallel implementations. The first proposal includes the native Material
snackbar, persistent Scaffold bottom-sheet composer, an adjusted
`Bottom_clearance`, and explicit Filled, Filled tonal, Outlined, and Text button
roles. Implementation may use reviewable batches, but those batches do not
defer any of these accepted parts to a later decision.

### Required framework migration

Use the new SDK repository commit consistently in:

- `logseq_journal.opam` and `logseq_journal.opam.locked`;
- `logseq_db_worker.opam` and `logseq_db_worker.opam.locked`; and
- the current-revision assertion in `test/source_boundary_test.ml`.

Historical implemented decision documents continue to record the revision they
implemented and must not be rewritten as current dependency metadata.

Define one application-owned Material theme and return the navigator through
`App.View.create ~theme ~body`. The existing application palette is light-only,
with a separate high-contrast-light variant. The initial application theme
should therefore use `Theme.Light`, supply valid light and dark `Theme.data` as
required by the API, and render the current application in the light variant.
Using `Theme.System` before the application has a complete dark palette would
allow framework Material widgets to become dark while custom journal surfaces
remain light.

Remove the outer `MaterialApp` around `BonsaiFlutterRoot` in
`flutter/lib/main.dart`. The standalone authentication-configuration
failure application may keep its own `MaterialApp` because no Bonsai runtime
root exists in that branch. Select the bonsai_flutter_tool custom-host mode so
`bonsai-flutter sync-host` validates but never rewrites the application-owned
`main.dart` entrypoint.

Update exhaustive `page_presentation` matches to handle `Modal_dialog`
explicitly. Do not add wildcard matches that would hide later navigation API
changes.

### Dialog adoption

Replace the obsolete dialog and overlay path with
`Material.alert_dialog` content presented by a dedicated
`Navigation.Modal_dialog` page. This covers:

- the account actions dialog;
- local graph copy reset confirmation;
- Capture draft discard confirmation; and
- Detail draft discard confirmation.

Confirmation dialogs should use the alert dialog's title, content, and action
slots directly. The account dialog may use alert content for its account
actions until a maintained Material menu or action-sheet component exists; it
must not introduce a new native widget or a second barrier implementation.
Every modal page must retain the current non-dismissible barrier policy and
explicitly define `can_pop`, focus, safe area, transitions, and stable page and
restoration identities. Remove `page_body` and application-local dialog
overlays when their final consumer is migrated.

### Snackbar adoption

Replace `timeline_notice_view` and its manually positioned overlay with
`App.Context.host_effects` and `Host_effect.show_snack_bar`:

- successful deletion presents `"Block and descendants removed"` with an
  `Undo` action;
- an `Action` close reason dispatches the existing undo effect exactly once;
- timeout, dismissal, swipe, hide, or removal does not dispatch Undo; and
- failed deletion presents `"Delete failed. Block restored."` without an
  action.

The host effect accepts text and an optional text action rather than an
arbitrary widget subtree. The application therefore gives up its custom
snackbar test IDs, palette, width, and manual position in favor of the single
framework presentation lifecycle. Delete state, retry behavior, and the
existing bounded undo lifetime remain application-owned. The native Material
appearance and loss of those application-specific presentation details are
accepted consequences of this decision.

### Persistent Capture composer adoption

Move the existing `Native_widget.Message_composer` unchanged into
`Material.scaffold ~bottom_sheet`. Keep its native widget key, event protocol,
button IDs, disabled-state policy, SafeArea behavior, and full-Capture action.
Do not replace the composer with a FAB or a Material text field.

Flutter `Scaffold.bottomSheet` positions the persistent sheet above keyboard
insets but overlays rather than constrains its body. Remove the positioned
composer overlay, but retain `Bottom_clearance` as the single application-owned
body/sheet spacing mechanism. Adjust its sparse extent for text scale and the
bottom SafeArea so the last journal row can scroll fully above the composer at
normal and large text scales, with and without keyboard and safe-area insets.
Do not add body padding or a second clearance fallback. The timeline must keep
its stable keyed items, bounded retention window, visible-range contract, and
scroll-anchor policy.

### Button role adoption

Replace the text-button-only implementation of `action_target` with an explicit
application button role that selects one of the maintained constructors:

- Filled for primary commit actions such as Save, Unlock, and destructive
  confirmation after the user has already entered a confirmation dialog;
- Filled tonal or Outlined for secondary creation and retry actions where a
  stronger affordance than text is required; and
- Text for navigation, dismissal, Undo, and other tertiary actions.

The role must be chosen at each call site rather than inferred from labels.
Existing enabled state, event binding, test identity, minimum target size, and
accessible label and hint remain intact. Visual colors, shape, density, and tap
target defaults come from the application Material theme; do not recreate
Flutter `ButtonStyle` in application code. Material 3 theme-default visual
changes for Filled, Filled tonal, Outlined, and Text roles are accepted and are
part of the first proposal.

### Deliberately deferred components

Do not adopt the following APIs without a separate product requirement:

- `Material.app_bar` for the journal header, because its current public shape
  cannot represent the account action, two-line date context, adaptive height,
  and existing semantics without nesting the custom header inside an app bar;
- `Material.Floating_action_button`, because the persistent composer already
  owns the primary creation affordance;
- `Material.navigation_bar`, because Timeline, Capture, and Detail are not peer
  top-level destinations;
- `Material.Radio_group`, because graph selection is an immediate list action,
  not retained form selection;
- sliders and range sliders, because there is no numeric setting; and
- filter, choice, action, and input chips, because the current multi-state task
  cycle has no one-to-one chip interaction without a product redesign.

`Material.list_tile`, `divider`, and `card` may remain future local cleanups,
but they predate this framework update and are not part of this decision. The
change must add no new divider, and every rendered screen must continue to
contain no more than three dividers.

No OCaml file under `spec/`, no Dune file, and no OCaml file in the
`bonsai_flutter` repository is in scope.

## Decision

Implement the full proposal in reviewable batches. First align dependency and
host metadata with SDK repository commit
`9b345b90fea476391d19092675abd665655e586a`, then migrate application theme and
root ownership, dialogs, snackbars, the persistent Capture composer, and
explicit Material button roles. Remove every replaced application-owned path;
do not retain compatibility wrappers, duplicate presentation lifecycles, the
positioned composer overlay, or a second body-spacing fallback. Retain and
adjust `Bottom_clearance` because the Flutter bottom-sheet slot overlays the
Scaffold body.

## Alternatives considered

### Perform only the minimum source-compatible upgrade

Migrate Theme, the root view, the custom host, and dialogs, but leave the
snackbar, composer overlay, and text-button-only helper unchanged. This is the
lowest-risk way to restore compilation, but it leaves application-owned
presentation and geometry that the upgraded framework now supports directly.
Rejected as the first proposal because the accepted scope includes snackbar,
composer, adjusted clearance, and button-role adoption. The implementation may still
sequence mandatory compilation fixes before component adoption inside the same
proposal.

### Adopt every new Material component

Rejected. Adding FAB, NavigationBar, Radio, Slider, RangeSlider, and Chips
without an existing interaction to replace would create new product behavior
and state solely to exercise framework APIs. Component availability is not a
product requirement.

### Keep generic application-local dialog overlays

Rejected. `Material.dialog` was removed specifically to separate the visual
alert surface from modal route ownership. Rebuilding the same primitive with
`decorated_box`, stack barriers, or a private native widget would retain two
modal lifecycle models and bypass `Navigation.Modal_dialog` focus, restoration,
and back behavior.

### Keep the custom snackbar for visual fidelity

This preserves the current palette, width, test IDs, and exact position above
the composer. It also retains application state and positioning for a transient
surface now owned by a typed host effect. Rejected: the native Material
snackbar and the loss of application-specific presentation details are
explicitly accepted.

### Remove Bottom_clearance after moving the composer to the scaffold

Rejected. Flutter `Scaffold.bottomSheet` avoids keyboard insets but overlays its
body, and the framework adds no compensating body constraint. Removing the
synthetic slot would allow the last timeline row to remain behind the composer.
Keep one adjusted `Bottom_clearance`; do not add parallel body padding or restore
the positioned composer overlay.

### Switch the application theme to System mode immediately

Rejected for the first migration. Framework-owned controls would select dark
Material defaults while journal rows, headers, dialog content, and other custom
surfaces still resolve only light and high-contrast-light palettes. Dark mode
requires a separate complete palette decision.

### Preserve obsolete APIs through application compatibility wrappers

Rejected. A wrapper cannot restore the removed framework dialog ownership or
old widget-only application result without recreating the obsolete paths. The
repository explicitly drops backward compatibility and removes obsolete
implementations.

## Acceptance criteria

- All maintained manifests, lockfiles, and source-boundary assertions select
  `9b345b90fea476391d19092675abd665655e586a`; no maintained dependency path
  selects `a6bd9aa9906c0e49f0cc365e5ba33270e89655e6`.
- The application component returns an `App.View.t` containing an explicit
  application-owned theme and the navigator root. The initial rendered mode is
  Light, and high-contrast behavior remains available without a mixed dark and
  light tree.
- The live `BonsaiFlutterRoot` has no host-owned outer `MaterialApp`.
  Authentication configuration failure remains renderable before a runtime is
  created, and the configured application still starts only after Amplify
  preparation succeeds.
- Host synchronization succeeds with no diff, while every Flutter and Apple
  platform build uses the custom `flutter/lib/main.dart` entrypoint.
- No source or test references `Ui.Material.dialog` or the removed generic
  material dialog node. Every account, reset, Capture-discard, and
  Detail-discard surface is an `AlertDialog` presented by `Modal_dialog` with
  stable route identity, correct barrier policy, focus, SafeArea, and back
  behavior.
- All `page_presentation` matches are exhaustive and test `Modal_dialog`
  explicitly.
- Delete success and failure use `show_snack_bar`. Undo is dispatched exactly
  once only for the action close reason, ordinary Bonsai recomputation does not
  replay a snackbar, and shutdown or route replacement leaves no pending
  presentation.
- The MessageComposer is the Scaffold bottom-sheet child and no positioned
  composer overlay remains. `Bottom_clearance` is the only reserved body extent;
  its sparse extent adjusts for text scale and bottom SafeArea. The last journal
  row remains visible above the composer at normal and large text scale, with
  and without a bottom safe-area inset, and while the keyboard is shown.
- The composer keeps both button IDs and policies, does not autofocus, preserves
  draft text across unrelated frames, and continues to open and submit Capture.
- Primary, secondary, and tertiary actions use explicit Material button roles.
  Disabled behavior, minimum targets, semantics, keyboard activation, and test
  identities remain correct.
- No FAB, NavigationBar, RadioGroup, Slider, RangeSlider, or chip state is added.
  The custom header and existing modal Capture bottom sheet retain their current
  product roles.
- No screen renders more than three dividers.
- Focused OCaml tests cover application theme ownership, dialog presentation,
  snackbar close reasons, composer placement and geometry, button variants, and
  exhaustive navigation matches. Existing timeline, semantics, route, compiled
  runtime, deletion, pagination, scroll-anchor, RTL, text-scale, reduced-motion,
  and high-contrast coverage remains green.
- `spec-dev-tool check --all`, `dune runtest`,
  `bonsai-flutter sync-host --check`, Flutter tests and analysis through
  `bonsai-flutter exec`, the macOS debug build, the unsigned iOS debug build,
  and iPhoneOS toolchain verification all succeed.

## Consequences

The repository now selects SDK commit
`9b345b90fea476391d19092675abd665655e586a` in all maintained manifests and
lockfiles. The application returns one light-mode `App.View` with light, dark,
and high-contrast-light Material theme data. `BonsaiFlutterRoot` owns the live
`MaterialApp`; the custom authentication host supplies only the inherited
MediaQuery, localization, directionality, and Theme state needed before the
authenticated Bonsai application is visible. The standalone Amplify
configuration-failure branch remains an independent Material application.

Account actions, local-cache reset, Capture discard, and Detail discard now use
Material alert content on dedicated non-dismissible modal-dialog pages. Each
page has a stable page key, restoration identity, barrier label, SafeArea,
focus request, explicit transition duration, and `can_pop:false`. The obsolete
generic dialog and `page_body` overlay paths have been removed.

Delete notices now use the host Material snackbar. A successful staged delete
supplies the `Undo` action, and only the `Action` close reason invokes the
existing undo handler. Dismiss, swipe, hide, remove, and timeout responses do
not undo. The active request is cancelled when the notice clears or the graph
or route no longer owns the timeline. Application-specific snackbar palette,
geometry, widget IDs, and overlays no longer exist.

The persistent MessageComposer is the journal Scaffold's bottom sheet. Its
stable key, two button IDs, event protocol, autofocus policy, and Capture
dispatch remain unchanged. The positioned overlay is gone. `Bottom_clearance`
remains the only body reservation and is now calculated from the composer's
five-line expanded bound, the selected row profile's scaled line height, the
composer margin, and the bottom SafeArea. The bottom sheet applies the same
SafeArea explicitly because Flutter removes the body's bottom padding from the
sheet context. Runtime coverage verifies the final row above the composer at
normal and 3.2x text scale and with a keyboard inset.

Every `action_target` call now declares Filled, Filled tonal, Outlined, or Text
role explicitly while retaining its prior enabled state, minimum target,
handler, semantics, key, and test identity. Obsolete Material icon code points
exposed by the current Flutter SDK were also replaced with the maintained Add,
Arrow upward, Refresh, and Account circle code points. No deferred Material
component or additional divider was introduced.

Verification completed successfully for `dune runtest`, the focused compiled
application tests, source boundaries, `flutter analyze`, the complete Flutter
test suite through `bonsai-flutter exec`, the real-OCaml runtime golden,
`bonsai-flutter sync-host --check`, the macOS debug build, and generation plus
Mach-O verification of the iPhoneOS arm64 native artifact. After installing the
iOS 26.1 Simulator runtime and iOS 26.1 Platform Support component, Xcode exposes
both generic and connected-device iOS destinations. The final unsigned iOS
debug build succeeds, including Mach-O and app-bundle verification of
`Runner.app`.

## Risks

- Material alert dialogs, snackbars, and button variants inherit theme defaults
  and may not match the current application-drawn colors, spacing, widths, or
  test-visible widget structure.
- Removing the outer `MaterialApp` changes ownership of Navigator,
  ScaffoldMessenger, focus, restoration, and inherited theme state. A stale
  custom host could produce duplicate or missing application infrastructure.
- Moving the composer into `Scaffold.bottomSheet` changes keyboard insets and
  SafeArea treatment while leaving the body unconstrained. An undersized
  `Bottom_clearance` could hide final journal rows; an oversized extent could
  add unnecessary trailing space and affect visible-range pagination.
- A snack bar host effect is imperative. Incorrect dependency tracking could
  replay a notice, lose Undo, or dispatch Undo after the application state no
  longer owns the deletion.
- Modal dialogs become Navigator pages rather than body overlays. Incorrect
  page ordering or `can_pop` policy could dismiss drafts, expose two dialogs,
  or make the underlying account action reachable while confirmation is active.
- Material button defaults may change layout at high text scale or on macOS,
  particularly where multiple actions currently share an expanded row.
- The host packages and iPhoneOS framework SDK must describe the same protocol
  and ABI generation. Updating repository pins without verifying the controlled
  iPhoneOS toolchain could restore host builds while leaving device builds
  mismatched.
- The broad final state crosses dependency metadata, OCaml view ownership,
  navigation, host Dart, generated Dart, timeline geometry, and tests. It should
  be delivered in reviewable batches even though the document owns one coherent
  adoption decision.

## Questions

None. The user accepted the native Material snackbar presentation, the
`Scaffold.bottom_sheet` composer migration with a retained and adjusted
`Bottom_clearance`, and explicit Filled, Filled tonal, Outlined, and Text button
roles with Material 3 theme-default visual changes.
