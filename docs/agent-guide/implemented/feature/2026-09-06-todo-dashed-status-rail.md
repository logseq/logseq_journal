# Todo Dashed Status Rail

## Problem

TODO currently uses a solid vertical status rail, like the other task statuses.
The requested change is to make TODO distinguishable by a dashed rail while
preserving its existing color and placement.

The rail is rendered separately in `app/journal_row.ml` for top-level entries
and `app/journal_timeline.ml` for expanded direct children. Both use a rounded
decorated box. `app/journal_visual_tokens.ml` defines a width of 4 logical pixels
and a corner radius of 2. Rail height is the visible line count multiplied by
the active layout profile's block line height.

## Proposal

Render `Journal_model.Todo` as vertically repeated rounded segments in both
locations. The user-confirmed geometry is a 6-logical-pixel segment followed
by a 4-logical-pixel transparent gap, retaining the existing width, radius,
theme color, and outer rail height. Start the pattern at the top and shorten
the final segment when necessary to stay inside the rail bounds.

Prefer the existing built-in layout and decorated-box primitives exposed by
`Bonsai_flutter_ui`, consistent with `docs/ux-guidelines.md`. Place segments in
a fixed-size container using the already computed height; no new dependency
or custom Flutter painter is expected. Keep both render sites consistent.

All other statuses retain their current solid rails, and `No_status` continues
to have no rail. Task status controls, status icons, semantics, text layout,
RTL placement, persistence, and synchronization retain their current behavior.
This decision introduces no public task model or protocol changes, compatibility
paths, fallbacks, or migrations. No changes to dune files, OCaml files under
`spec/`, or OCaml files in the bonsai_flutter repository are planned.

On 2026-09-06, the user confirmed this geometry and its application to both
top-level entries and expanded direct children. This proposal records the
agreed scope; implementation and validation are recorded below.

## Decision

`Journal_row.rail_body` builds the bounded rounded TODO segments and is shared by
top-level rows and expanded child previews. Existing solid-status rendering and
outer rail geometry are retained. The TODO visual assertion was first observed
failing against the solid renderer, then passed with the shared segmented body.

See [implementation validation](../../../test-reports/2026-09-06-proposed-docs-validation.md).

## Alternatives considered

### Dotted rail

Repeated circles would also distinguish TODO, but communicate a dotted rather
than dashed line. Rounded short segments match the requested visual treatment.

### Custom painter or dashed-border dependency

These could draw the pattern but add rendering or dependency work for geometry
that the existing fixed-height layout can express. Reconsider only if the
existing primitives cannot implement the agreed appearance efficiently.

## Acceptance criteria

- TODO displays the agreed dashed pattern in top-level entries and expanded
  direct children, including single-line and multiline content.
- Rail width, outer height, color, text spacing, and leading-edge placement
  remain consistent with the current layout in LTR and RTL.
- Segments remain within the computed rail bounds, including a partial final
  segment; text scaling and layout-profile changes produce no overflow.
- Switching between TODO, another task status, and no status updates the rail
  correctly without changing task interactions or accessibility labels.
- Review the appearance in light, dark, and high-contrast presentations.
  Adapt the existing rail assertions in `test/journal_semantics_test.ml`, which
  currently expect a single solid decorated box for TODO, and review affected
  existing visual fixtures where available. This is a presentation change,
  not a reducer defect; no new reducer, persistence, or sync tests are planned.

## Consequences

- A fixed dash cadence may leave a short final segment or a trailing gap; the
  agreed top-aligned pattern needs visual review at actual row heights.
- Two render sites can diverge if only one is updated or their geometry differs.
- Repeated segments add widget nodes proportional to visible rail height; keep
  generation bounded by the already measured visible content.
- Existing tests assume that the rail's test ID identifies a solid decorated
  box. Update those expectations to the agreed appearance without retaining
  obsolete solid-TODO rendering merely to satisfy them.

## Questions

None. On 2026-09-06, the user confirmed the top-aligned rounded pattern:
6 logical pixels per segment, 4 per gap, with a shortened final segment when
needed, applied to both top-level entries and expanded direct children.
