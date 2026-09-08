# Unify Appbar Title Typography

## Problem

The AppBar date uses normal 20-point day-heading typography, while Favorites uses semibold 24-point header typography with different scaling and title height. The user requests matching style, font, and size.

## Decision

Both titles now use the existing day-heading token and date scaling policy, inheriting the same AppBar font family and foreground. They share text-style construction and title height. The obsolete Favorites-only sizing path and unused header-title token were removed. The weekday remains secondary. This complies with docs/ux-guidelines.md.

## Alternatives considered

### Enlarge the date to match Favorites

This would disrupt the established shared typography between the AppBar date and timeline dates. Matching Favorites to the existing date preserves that hierarchy.

## Acceptance criteria

- The date and Favorites use identical font family, size, weight, line height, foreground, and text scaling at each viewport width.
- Switching titles preserves the same toolbar height, with existing header layout checks passing.

## Consequences

- Favorites becomes smaller and lighter, intentionally matching the date. Existing narrow-viewport and large-text layout coverage will verify clipping and control separation.

## Validation

- `dune build @all` and `dune runtest` passed.
- The existing Flutter header layout suite passed all 117 tests through the installed `bonsai-flutter exec --profile=debug`, including narrow viewports, large text, RTL, themes, contrast, and retained destination switching.
- `ocamlformat --check` passed for all four changed OCaml files.
- Existing typography assertions were updated for the shared token; no new regression tests were added for this bounded presentation change. The presentation owner is `Journal_header`, with native typography and layout rendered by Flutter.
- No OCaml files under `spec/`, dune files, or bonsai_flutter OCaml source were modified.
