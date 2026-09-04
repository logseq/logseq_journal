# Adapt Latest Bonsai Flutter

## Problem

The active OPAM switch installs `bonsai_flutter`, `bonsai_flutter_test`, and
`bonsai_flutter_tool` from revision
`3d2a540d886839fb243ce78f4bcc38da13c600a9`, while the application and worker
manifests still pin revision
`de1196c2663b43388ebf04bd0612c5050edef753`. The newer revision intentionally
removes the overlapping generic `Widget.button` and
`Widget.Sliver.app_bar` APIs, makes `Material.App_bar.sliver` the sole public
scrolling Material app-bar constructor, and extends progress-indicator node
data with an explicit `wavy` field.

The project no longer compiles against the installed framework. The current
test build reports an unbound `Ui.Widget.Sliver.app_bar`, an unbound
`Ui.Widget.button`, and exhaustive-record-pattern warnings for the new
progress-indicator shape. Leaving manifests pinned to the previous revision
would also allow a fresh environment to install a framework and renderer that
do not match the API and protocol used during local development.

## Proposal

Adopt bonsai_flutter revision
`3d2a540d886839fb243ce78f4bcc38da13c600a9` consistently in the application
and worker manifests and lockfiles. Synchronize the custom Flutter host with
the installed `bonsai-flutter` tool and retain only generated changes produced
by that operation.

Migrate the Journal header to `Ui.Material.App_bar.sliver`. Select the built-in
medium, square, compact Material app-bar presentation and keep the current
pinned, non-floating, centered behavior. Preserve the date context, account
and error actions, subtitle, and connecting progress feedback using the new
app-bar's title and action inputs. Remove obsolete custom height, flexible
space, divider, and stretching configuration rather than recreating the old
framework implementation locally.

Prefer the newly integrated Material 3 Expressive components wherever the
application already presents the corresponding Material concept:

- use `Ui.Material.list_tile` for status-sheet choices and authorized graph
  choices, including controlled enabled and selected state plus leading icons;
- replace the removed choice-chip path with `Ui.Material.Chip.filter` for the
  controlled typography filter choices;
- use the new string-title `Ui.Material.Dialog.alert` contract and let the
  Material component own dialog-title presentation; and
- wrap icon-only account, error, and catalog-refresh actions in
  `Ui.Material.Tooltip.plain` while retaining their explicit accessibility
  semantics.

Do not mechanically replace design-independent layout, scrolling, text, or
compound timeline-row primitives when no equivalent Material component owns
their product semantics.

Update tests before implementation to require the new Material-owned app-bar,
filter-chip, list-item, dialog, and tooltip paths; reject removed generic or
legacy component constructors; verify the selected status row remains
disabled; and assert that the flat indeterminate progress node uses
`wavy = false`. Keep all product behavior and public application interfaces
unchanged outside these framework boundary adjustments.

## Decision

Adopt bonsai_flutter revision
`3d2a540d886839fb243ce78f4bcc38da13c600a9` and use its Material-owned APIs
directly. The Journal header uses the compact medium square expressive sliver
app bar; status and graph choices use expressive list items; typography choices
use expressive filter chips; alerts use Material-owned string titles; and
icon-only account, error, and graph-refresh actions expose expressive tooltips.

Remove the obsolete generic button, widget sliver-app-bar, choice-chip, custom
flexible-space, and header-divider paths. Keep generic widgets only for concepts
that do not have a Material component equivalent.

## Alternatives considered

### Retain the previous bonsai_flutter revision

This would restore compilation temporarily, but it would ignore the requested
upgrade and preserve a manifest/environment mismatch. It would also retain
APIs that bonsai_flutter deliberately removed without a compatibility layer.

### Add local aliases for removed generic APIs

Aliases could minimize call-site edits, but they would recreate obsolete
paths and obscure Material ownership. The repository explicitly rejects
backward-compatibility layers for removed contracts.

### Keep custom pressable status rows

The existing rows can be made to compile by removing the disabled generic
button while retaining a custom row plus `Widget.pressable`. The new
`Material.list_tile` directly owns list-item geometry, selection, disabled
state, and a leading icon, so the custom composition is no longer preferred.

### Rebuild the previous flexible-space app bar outside the framework

An application-owned stack could reproduce the old arbitrary heights,
divider, and collapse geometry. That would bypass the new built-in Material
component and duplicate scrolling app-bar behavior. The project UX guidance
prefers the appropriate built-in Flutter component.

## Acceptance criteria

- Application and worker manifests and lockfiles pin bonsai_flutter revision
  `3d2a540d886839fb243ce78f4bcc38da13c600a9`.
- Maintained application and test sources contain no use of
  `Ui.Widget.button` or `Ui.Widget.Sliver.app_bar`.
- The Journal header is a pinned, non-floating, non-snapping
  `Ui.Material.App_bar.sliver` with explicit medium, square, compact, centered
  presentation.
- The header retains its date context semantics, subtitle, account action,
  optional error action, and flat indeterminate connecting progress feedback.
- Typography choices use `Ui.Material.Chip.filter`; status and graph choices
  use `Ui.Material.list_tile`; alert pages use the new string-title dialog
  contract; and icon-only header and refresh actions use
  `Ui.Material.Tooltip.plain`.
- The selected status-sheet list item is disabled and selected and has no tap
  action; enabled list items retain their exact commands.
- Maintained sources contain no `Ui.Material.choice_chip`, old widget-valued
  alert-dialog title, or custom status-sheet pressable row.
- The implementation adds no divider and stays within the maximum of three
  dividers.
- No OCaml file under `spec/`, Dune file, generated host file by hand, or OCaml
  file in the bonsai_flutter repository is modified.
- Relevant OCaml tests, the complete Dune test suite, host synchronization
  check, Flutter tests and analysis through `bonsai-flutter`, the macOS debug
  build, `spec-dev-tool check --all`, and `git diff --check` pass.

## Risks

- Built-in Material medium app-bar geometry is not pixel-identical to the
  removed arbitrary-height flexible-space implementation. The change accepts
  the framework's standard geometry rather than adding an application
  compatibility recreation.
- The title region now owns the subtitle and progress content, so available
  width is constrained by the leading and action regions. Existing one-line
  clipping remains necessary at large text scales.
- The worktree contains extensive unrelated staged and unstaged changes.
  Adaptation edits must be limited to directly affected files and generated
  host output must be reviewed separately.
- The new renderer protocol is intentionally incompatible with old generated
  hosts. Pin, installed packages, synchronized host, and native build must all
  resolve to the same published revision.

## Questions

None. The requested upgrade and the published bonsai_flutter migration
decision determine the replacement APIs, and the user explicitly requested
that new Material 3 Expressive components be preferred when applicable.

## Consequences

- The application and worker resolve the same bonsai_flutter revision as the
  active development switch.
- The Journal header follows the expressive component's standard geometry
  instead of preserving custom legacy heights and divider placement.
- Status choices, graph choices, typography filters, dialogs, and icon-action
  help text are rendered by the framework's Material 3 Expressive integration.
- The Flutter lockfile now records the expressive renderer's transitive
  `material_3_expressive`, `material_ui`, shape, color, and motion packages.

## Implementation evidence

The focused source-boundary and Journal semantics tests failed first against
the removed framework API and old revision, then passed after the direct
cutover. The complete Dune test suite, generated-host synchronization check,
scoped Flutter analysis, standard Flutter test suite, OCaml and Dart format
checks, `git diff --check`, native complete-object verification, and macOS debug
application build pass. The environment-gated real-runtime golden suite cannot
be run from this worktree without an external support root because its retired
local fixture executable has already been removed by the surrounding work.
