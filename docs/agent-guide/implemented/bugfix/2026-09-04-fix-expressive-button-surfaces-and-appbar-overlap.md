# Fix Expressive Button Surfaces And Appbar Overlap

## Problem

The macOS application shows two regressions after adopting the latest Material
3 Expressive renderer. Standalone `M3EListItem` controls use their default
filled card surface, so graph choices and status choices appear as large gray
buttons instead of controls that share the page or sheet background.

The medium expressive sliver app bar passes the same title to both the
collapsed toolbar and `FlexibleSpaceBar`. During timeline scrolling those two
title instances overlap visibly, and at intermediate collapse offsets the text
becomes unreadable.

Real macOS operation also reports a 15-pixel horizontal `RenderFlex` overflow
in the Account expressive dialog because six action buttons are placed in the
dialog's single action row.

## Proposal

Keep Material 3 Expressive ownership while choosing components whose visual
contracts match the product. Replace the standalone filled list items used for
graph and status choices with full-width `Ui.Material.text_button` controls.
Compose their leading icon and label inside the button, retain the exact
enabled, selected, command, hit-target, test-ID, and accessibility behavior,
and leave the background transparent in idle state.

Use the small square compact `Ui.Material.App_bar.sliver` variant for the
Journal header. The small expressive variant has no flexible-space title, so it
provides one stable title at every scroll offset while preserving pinned,
non-floating, non-snapping, centered behavior and both header actions.

Move the Account dialog's operational controls into a vertical content column
as transparent expressive text buttons and keep only Cancel in the dialog
action row. Preserve the existing commands and destructive-operation wording;
this is a layout and surface correction, not a behavior change.

Add failing OCaml boundary/semantics tests and Flutter runtime assertions before
changing production code. Verify the final result in the real macOS host at its
current narrow window width and inspect Flutter logs for layout exceptions.

## Decision

Use Material 3 Expressive text buttons for graph choices, status choices, and
Account dialog controls. Their idle surfaces are transparent, while the
framework continues to own hover, focus, pressed, and disabled states. Retain
the selected status in explicit semantics and disable its handler.

Use the small square compact expressive sliver app bar. It keeps one pinned
title at all scroll offsets and does not create the medium variant's duplicate
flexible-space title. Put the Account controls in a vertical content column and
leave only Cancel in the dialog action row.

## Alternatives considered

### Keep standalone expressive list items and override their color

The current bonsai_flutter `Ui.Material.list_tile` contract exposes no color or
card-variant input. Adding an application-side wrapper cannot remove the filled
surface created inside `M3EListItem`, and modifying bonsai_flutter is outside
this repository's allowed scope.

### Keep the medium app bar and recreate collapse opacity locally

The expressive component owns its internal `FlexibleSpaceBar`, so the
application cannot independently animate or suppress one title. Rebuilding the
app bar would violate the preference for the built-in component.

### Use generic pressable rows

Generic pressables could provide a transparent surface, but expressive text
buttons already provide the required Material interaction, focus, disabled,
and hover behavior without restoring an obsolete generic button path.

## Acceptance criteria

- Graph and status choices use Material 3 Expressive text buttons and have no
  persistent gray idle surface.
- The selected status remains disabled and selected; enabled statuses retain
  their exact commands.
- The Journal app bar renders exactly one visible title when expanded,
  partially collapsed, and fully collapsed.
- The app bar remains small, square, compact, pinned, non-floating,
  non-snapping, and centered with account and optional error actions intact.
- The Account dialog fits at the current macOS window width without a
  `RenderFlex overflow`, and all commands remain reachable.
- Focused tests, the complete OCaml and Flutter suites, host synchronization,
  formatting, macOS debug build, real macOS interaction, and
  `spec-dev-tool check --all` pass.

## Risks

- The small app bar intentionally gives up the expanded-title treatment in
  exchange for a stable single title during scrolling.
- Text buttons have Material state layers only during interaction, so selected
  status must remain distinguishable through its icon, semantics, and disabled
  state rather than a persistent filled surface.

## Questions

- None. The user explicitly requested transparent button surfaces and reported
  the scrolling overlap; macOS operation provides the failing evidence.

## Consequences

- Graph and status choices share the surrounding page or sheet background in
  idle state instead of presenting filled gray cards.
- The Journal header no longer expands vertically, but its title remains stable
  and readable while the timeline scrolls.
- Account actions remain individually accessible without competing for one
  horizontal action row.
- Shared row-button content keeps icon, label, padding, and minimum hit-target
  geometry consistent across graph and status choices.

## Implementation evidence

The source-boundary test first failed on the remaining medium app bar and
standalone list items, and the Journal semantics test failed on sliver variant
1. Both pass after the cutover to text buttons and sliver variant 0. The full
Dune suite, generated-host check, scoped Flutter analysis, Flutter test suite,
OCaml and Dart formatting, and `git diff --check` pass.

The rebuilt macOS host was operated at a 687-pixel-wide window. Screenshots
confirmed transparent graph, status, and Account controls plus one title before
and after timeline scrolling. The Account dialog remained usable with every
action visible, and the Flutter run log contained no rendering or overflow
exception during the final pass.
