# Graph Catalog Overflows macOS Window

## Problem

After removing only local catalog/mirror state to verify a fresh server download,
the App discovered 13 authorized graphs and rendered the graph picker in the default
800 by 600 macOS window. Flutter reported:

    A RenderFlex overflowed by 98 pixels on the bottom.

manager_page builds the title and every graph action as fixed children of a vertical
Flex, then places that column in a static body. It has no scrollable or expanded
list. The semantics tree placed Invest, the last graph, at y=586 through y=600
instead of its intended 44-pixel height, confirming that content is clipped and not
merely a Debug paint artifact.

The overflow occurs on a normal App window and scales with catalog size, text scale,
localization, and window height. Authorized graphs near the bottom can become
unreachable.

## Decision

Render graph choices in a bounded, vertically scrollable list. Keep the title and
give each graph a stable key and semantic label, and preserve keyboard/focus
traversal while scrolling. Place Refresh in the top-right toolbar so it remains
visible while graph rows scroll. The action must have a recognizable icon, tooltip,
stable semantic label, and keyboard focus target; it must not expose only a private
glyph character.

The loading, error, password, and progress states may remain compact static bodies;
only variable-length catalog content needs list layout.

### Implementation outcome

The awaiting-selection route now uses a bounded vertical viewport with sliver
rows, stable graph/action keys, and a fixed toolbar containing `Choose a graph`
and an accessible refresh icon. The refresh control remains outside the scroll
content and exposes a stable test ID, label, hint, focusability, and tap action.

macOS testing displayed all 13 authorized graphs in the constrained window,
scrolled from the first entries through `Invest`, and refreshed the catalog while
the toolbar remained visible. Compact manager phases continue to use static
presentation.

## Alternatives considered

### Shrink graph buttons to fit

Rejected because the catalog is unbounded and shrinking violates minimum target
sizes and accessibility.

### Increase the default window size

Rejected because users can resize the window, and larger catalogs or text scales
will overflow again.

### Clip excess graphs

Rejected because clipping silently makes authorized graphs unreachable.

### Pin Refresh below the title or list

Rejected because a title-adjacent row consumes scarce vertical space, while a
list-bottom action becomes unreachable without scrolling through a large catalog.
Refresh is a catalog-wide command and belongs in the persistent toolbar.

## Acceptance criteria

- All 13 observed graphs and the refresh action are reachable at 800 by 600 without
  a RenderFlex overflow.
- Refresh remains visible in the top-right toolbar while graph rows scroll and
  exposes a meaningful tooltip, semantic label, and keyboard focus target.
- Catalogs larger than one viewport scroll without shrinking the 44-pixel action
  targets.
- Keyboard and accessibility focus can reach every graph and automatically reveal
  the focused row.
- The picker remains usable at supported large text scales and with longer localized
  graph names.
- Empty, loading, failure, and single-graph states retain stable layout.

## Consequences

- Catalog size no longer determines whether an authorized graph is reachable.
- The fixed toolbar consumes a bounded portion of the route while graph rows own
  the remaining scroll viewport.
- Stable keys and semantics preserve focus identity as rows move through the
  viewport.

## Risks

- Nesting a scrollable manager body inside the navigation shell requires explicit
  height constraints.
- Focus restoration must not jump to the first row after catalog refresh.
- The toolbar must remain usable at narrow window widths and large text scales
  without reducing the Refresh hit target.

## Questions

- None. Refresh is a persistent top-right toolbar action while graph rows scroll.
