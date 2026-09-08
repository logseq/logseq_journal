# Journals Favorites Navigation

## Capture follow-up decision

The user subsequently requested restoring Expandable_message_composer and
explicitly accepted modal navigation blocking and loss of native draft restoration
after destination removal. The original persistent Capture adapter and its
registration have been removed. The following implementation history describes
the initial feature; its Capture adapter and draft-restoration requirements are
superseded by [Restore Expandable Capture](../bugfix/2026-09-08-restore-expandable-capture.md).

## Problem

The app currently opens the journal timeline as its only root destination. Users
cannot browse the favorites already stored in their Logseq graph.

The requested change adds a bottom NavigationBar with exactly two destinations,
`Journals` and `Favorites`, with Journals selected on launch. Favorites must use
the existing timeline visual language and have no horizontal row swipe actions.
On 2026-09-08, the user confirmed that Favorites should show **one row per
favorite target, in favorite order**, rather than a feed of blocks grouped by
favorite page. The user subsequently confirmed that first-version Favorites rows
do nothing when clicked and that Favorites does not display Capture. This
decision records the approved implementation, with authorization and verification
results below.

### Evidence from Logseq

Inspected `/Users/rcmerci/gh-repos/logseq` at HEAD `263fd97cbd`. Paths below are
relative to that checkout:

| Source | Observed behavior |
| --- | --- |
| `deps/common/src/logseq/common/config.cljs`, `favorites-page-name` | The internal page name is `$$$favorites`. |
| `deps/db/src/logseq/db/sqlite/create_graph.cljs`, `build-favorites-page` | Creates a Page-tagged entity with that name/title, `:logseq.property/hide? true`, and `:logseq.property/built-in? true`. |
| `deps/db/src/logseq/db/frontend/db.cljs`, `build-favorite-tx` | A favorite membership block has an empty title and `:block/link [:block/uuid target-uuid]`. Its title is not the favorite's display text. |
| `src/main/frontend/worker/handler/graph.cljs`, `get-favorite-pages` | Sorts direct children by Logseq order, resolves `:block/link`, and removes recycled targets. The API calls these page-block entities; do not assume every target is a journal. |
| Same file, `reorder-favorites-ops` | Reordering can rewrite the membership blocks' links without moving those blocks. Watching only child insertion/removal is insufficient. |
| `src/main/frontend/worker/handler/render_resource/basic.cljs`, `favorite-targets` / `favorites` | Resolves linked targets, emits target summaries, and observes both favorites children and target entities. |
| `deps/db/src/logseq/db/frontend/entity_util.cljs`, `recycled?` | Recycling includes deletion on the entity or an ancestor. |

The sidebar's favorite resource is a useful semantic reference. Its legacy
worker reader and render-resource reader differ when the hidden page is absent:
the former yields no list, while the latter reports a missing-page error. The
missing-page policy below is therefore an explicit product recommendation.

### Current application boundaries

Inspected this checkout at HEAD `4d19f87`:

- `app/application.ml` constructs the timeline Scaffold and Capture composer.
  Graph startup, requests, completion reconciliation, and visible-range events
  are currently wired around one timeline.
- `app/journal_timeline.ml` composes `Journal_row.view` with status/delete
  Slidable panes. `delete_enabled = false` already avoids the Slidable wrapper,
  while `actions_enabled = false` only disables actions. Favorites should render
  the shared row directly, without constructing either pane.
- `app/journal_row.ml` owns row typography, status rails, text truncation, sizing,
  and disclosure. A row with children toggles direct-child previews on press;
  a childless row is not currently a detail-navigation button.
- `app/journal_graph_projection.ml` accepts only live journal pages through
  `page_of_summary`. `app/journal_model.ml` requires a valid journal day. Neither
  is a suitable model for an arbitrary favorite page.
- `app/journal_routes.ml` models one Timeline root and a block detail route,
  with one return anchor. It has no ordinary-page detail destination.
- `logseq_db_types/lib/graph_types.mli` exposes pages and blocks, but its block
  type has no `:block/link` field. A generic `page_selector` type exists, but the
  active worker protocol only looks up a page by UUID.
- `logseq_db_worker/contract/protocol.mli` provides journal listing, UUID reads,
  children, and page trees; it has no favorites read command. The public overlay
  API in `logseq_overlay_db/spec/database.mli` also lacks a favorites/name read.
- The installed `bonsai_flutter/ui/material.mli` under
  `/Users/rcmerci/.opam/bonsai-flutter-v017-exact/lib/` exposes
  `Navigation_destination.create`, `navigation_bar`, and the Scaffold
  `bottom_navigation_bar` slot. The framework checkout exposes them too.

## Proposal

### Root navigation and presentation

Use the existing Material NavigationBar through `Ui.Material.navigation_bar`
and `Ui.Material.scaffold ~bottom_navigation_bar`. Use two labeled destinations
in the order Journals, Favorites, with selected indices 0 and 1. Let the native
Scaffold and navigation component own bottom safe-area layout. Keep the bar
outside the horizontally padded content region; avoid manually adding the bar's
height to content that the Scaffold already sizes above it.

Preserve immediate opening of the most recently used graph. Select Journals on
each app launch and on graph replacement. Do not persist the selected tab.
Switching tabs within the same open graph retains independent scroll anchors
and loaded windows, plus Journals' existing expansion state. Favorites has no
expansion state. Reselecting the current tab does not reset it. Do not remount
the graph service or restart sync when switching tabs.

Keep navigation at the root screen. Existing detail and management routes retain
their back behavior; any route opened from a tab must return to its originating
tab and anchor. System back on a root tab should retain the existing root
behavior rather than silently treating tab selection as a pushed route.

Favorites uses the same content width, row geometry, typography, theme tokens,
status rails where applicable, truncation, child-preview styling, and vertical
virtualization approach as Journals. Its header title is `Favorites`, retaining
the existing account/error actions and sync indicator. It has no date sections
or synthetic journal timestamps. Page rows display the resolved page title;
block rows display the resolved block title and real task status if available.
The hidden membership block's empty title and UUID never become user content.

Use a dedicated favorite presentation value and a typed constructor for
`Journal_row.Item`; reuse the row renderer without fabricating a Journal_model,
using `corrupt` as a general adapter, or duplicating the row layout. Keep page
and block identity explicit. The favorite membership UUID identifies its list
slot; the target UUID identifies content and any bounded static preview reads.
Preserve separate memberships if malformed data contains duplicate targets;
do not silently add a deduplication policy absent from the upstream reader.

Favorites rows are display-only in the first version. Clicking a row does
nothing: no expansion, navigation, editing, or mutation. Render no press handler,
tap feedback, disclosure control, button semantics, or accessibility activation
action, even when the target has children. Make this an explicit row interaction
mode rather than wiring a no-op callback into a still-pressable row. Static
collapsed summaries may reuse the existing row presentation, but do not render
expanded child rows or create child-loading interactions.

Favorites rows have no Slidable widgets, horizontal gesture handlers,
status/delete action panes, or corresponding accessibility actions. Journals
retains its existing row interactions. Vertical scrolling remains available.

Capture is shown only on Journals. Favorites renders neither the Capture FAB nor
the composer. Switching to Favorites dismisses the composer and its keyboard
while preserving the Journals draft; returning to Journals restores access to
that draft without automatically reopening the composer. A save already in
flight remains owned by Journals and completes without changing the active tab.
Capture continues to write to today's journal and never changes favorites.

### Favorites read contract

Recommend a bounded, resolved favorites read owned by the graph layer. Proposed
names in this section are interface design suggestions, not existing APIs:

1. Add `Database.get_favorites : snapshot -> limit:int -> cursor:Cursor.t option
   -> (Types.favorites_result, Types.read_error) result` to the overlay contract.
   It resolves the hidden page by exact graph name internally and reads ordered
   membership blocks and their linked targets from the same immutable logical
   snapshot, including the current overlay.
2. Add a worker `V2_list_favorites` request and typed result. Each result item
   contains membership UUID/order, target UUID/kind, display title, relevant
   block status, revisions, and any bounded static summaries used by the row.
   Represent page and block targets explicitly. Include the favorites page UUID
   when present, a projection revision, and an opaque continuation cursor.
3. Resolve `:block/link` as an entity reference inside the graph owner. Do not
   parse membership titles, substitute `:block/refs`, expose raw entity IDs to
   the app, or hard-code the built-in page's UUID.
4. Preserve Logseq membership order, using the existing graph ordering owner.
   Skip unresolved links and recycled targets, including recycled ancestors.
   Recommend that an absent hidden page or no valid favorites produces the
   `No favorites yet` empty state, with no graph writes. Read failures remain
   errors with Retry; they must not be converted to an empty list.
5. Bound both membership scanning and result/preview sizes. A page that filters
   out all scanned members may be empty and still have a continuation; the app
   must keep loading instead of incorrectly declaring the whole list empty.
   Cursors bind to the captured projection. On a stale cursor, restart the read
   and restore a surviving membership anchor rather than appending mixed data.

Resolving targets in a single read avoids an app-level request per row and avoids
mixing favorite order from one projection with target titles from another.
Static collapsed previews require a bounded preview budget in this read or an
explicitly bounded viewport read; do not eagerly load every favorite page tree.
Favorites has no expanded-child reads or page/block detail requests in this
version. Its presentation projection must support ordinary pages and blocks
without relying on a journal date.

### State, loading, and live updates

Keep graph lifetime in the existing service. Add an application-owned active
destination and a pure Favorites state owner for items, cursor, request token,
visible window, loading/error state, and anchor. Define public
events and completions before wiring side effects. Keep Journals' day-based feed
owner intact; Favorites should not invent days to reuse its pagination logic.

Load Favorites lazily on first selection from the local graph. Keep Journals'
initial local read independent of Favorites, with no network wait added to
startup. Distinguish initial loading, empty, initial error with Retry, and a
refresh failure that retains already loaded rows with a retry affordance.

Tag requests with graph generation and a destination-specific request generation.
An inactive tab may accept a still-current response into its own cache, but no
completion may change the selected tab, overwrite the other tab, or apply after
graph replacement. Coalesce refreshes while a read is in flight.

Invalidate on membership insertion/removal/order changes, membership `:block/link`
rewrites, target title/status changes, recycling/restoration, and child changes
that affect displayed static summaries. Existing pushes carry changed block/page UUIDs and structure interests;
the implementation must prove these cover all dependencies of the new read.
Track membership UUIDs as well as targets. Include filtered targets and relevant
ancestor changes in invalidation so restoration can make a favorite reappear.
When the hidden page is absent, page changes must trigger rediscovery of it.

Mark an inactive Favorites cache dirty and refresh it on selection. Refresh an
active list promptly while retaining a stable membership anchor. A removed
anchor moves to the nearest surviving row. A graph switch clears both tab caches,
anchors, child requests, and pending completions. No subscription may grow
without bounds as the user scrolls through targets.

### Interface prerequisite and implementation sequence

There is a concrete protected-spec gap: `logseq_overlay_db/spec/database.mli`
and `logseq_overlay_db/spec/types.mli` do not expose the proposed coherent
favorites read/result. Existing public reads cannot recover the missing link
attribute. Suggested changes are the `get_favorites` signature above and typed
membership/target/result records. Their rationale is to keep graph name lookup,
reference resolution, ordering, recycling, and snapshot consistency in the graph
owner rather than bypassing it from Application.

The product questions below are resolved. The user explicitly authorized these
specific spec `.mli` edits on 2026-09-08 before implementation. The public contract
and implementation were updated together. No dune file or bonsai_flutter OCaml
file is changed.

After the interface prerequisite is resolved:

| Stage | Expected touchpoints and outcome |
| --- | --- |
| 1. Graph contract and read | The two overlay spec interfaces above, their implementations, graph types if necessary, and `logseq_db_worker/contract/protocol.ml/.mli` plus codecs/validation expose a bounded resolved read. Update the existing protocol catalogs. |
| 2. Runtime and state | `app/journal_graph_request.ml/.mli`, `app/journal_graph_runtime.ml/.mli`, and Application expose Favorites requests/completions and destination-isolated state. Update push reconciliation. |
| 3. Shared presentation | `app/journal_row.ml/.mli`, `app/journal_graph_projection.ml/.mli`, and `app/journal_header.ml/.mli` support favorite content and header context without requiring a journal day. Add explicit display-only row rendering with no press/disclosure/swipe affordances; share static summary styling. |
| 4. Root shell | `app/application.ml` and `app/journal_routes.ml/.mli` wire navigation, anchors, lifecycle resets, and loading/error states. Show Capture only on Journals, preserving its draft and in-flight save across tab switches. |
| 5. Verification | Extend existing state, graph read, protocol, application view, and layout coverage at their actual ownership boundaries. Perform native visual and gesture checks. |

`app/dune` lists modules explicitly. Under the current no-dune-edit constraint,
place new state/presentation owners in clearly named submodules of existing
compiled modules. Creating standalone files would require separate explicit
authorization to update dune; it is not a hidden prerequisite of this plan.
Update replaced root-route callers together without legacy wrappers, storage
migrations, alternate favorites sources, or compatibility modes.

## Decision

Implement Journals/Favorites as two root destinations over the existing graph
service. Keep Favorites display-only and lazy, using a bounded resolved graph
read, an isolated public pure state owner, and the shared row renderer. Preserve
Journals draft/save state and independent tab scroll positions. Use application
native adapters for controller lifetime and the built-in Material NavigationBar.
The user authorized the two required overlay spec interfaces; dune and framework
source restrictions remain unchanged.

## Alternatives considered

### Read the hidden page through the existing timeline feed

The feed filters for journals, and the membership blocks have empty titles.
It cannot display the resolved favorites correctly and would require fake dates.

### Expose raw links and assemble Favorites in Application

This would still require public graph API changes for name discovery and link
data, while adding per-target reads and cross-snapshot reconciliation to the app.
A resolved graph read is the recommended boundary for this feature.

### Group the contents of all favorite pages into a timeline

The user explicitly selected one row per favorite target instead.

### Implement a custom bottom tab strip or a second row renderer

The native NavigationBar and shared row renderer already supply these visual
primitives. Duplicating them adds layout and accessibility ownership without
supporting a requested behavior.

## Acceptance criteria

- Launch immediately opens the last graph with Journals selected. The root has
  exactly two bottom destinations labeled Journals and Favorites.
- Favorites displays one primary row per valid linked target in Logseq favorite
  order, including non-journal pages. It never shows membership placeholders.
- External reorder, link rewrite, title changes, deletion/restoration, and
  favorites-page creation update the visible list without reopening the graph.
- Loading, empty, read failure, continuation, and stale-cursor recovery remain
  distinguishable. Large collections and child previews use bounded reads.
- Both tabs retain independent scroll state within the same graph, and Journals
  retains its expansion state. Favorites has no expansion state; delayed
  completions cannot contaminate another tab or graph.
- Favorites reuses timeline row typography/geometry and contains no left/right
  swipe affordances or accessibility actions. Journals swipes continue to work.
- Native visual checks cover light/dark themes, high contrast, RTL, narrow width,
  enlarged text, reduced motion, bottom insets, and keyboard/composer layout.
  Rows and navigation labels remain readable, tappable, and unobscured.
- Clicking any Favorites row, including a target with children, does nothing.
  Rows expose no disclosure controls, tap feedback, or activation semantics and
  cannot expand children or open detail routes.
- Favorites displays neither the Capture FAB nor its composer. Switching away
  from Journals closes the composer/keyboard and retains the draft. An in-flight
  journal save can complete without switching the selected tab.
- Follow `docs/ux-guidelines.md`: use appropriate built-in Flutter components,
  preserve most-recent-graph startup, add no dividers, and keep at most three.
- Implement no backward-compatibility layer or migration. Respect the protected
  spec, dune, and framework constraints.

### Verification ownership

Test destination selection, completion generation guards, dirty refreshes,
draft/save preservation, and anchor reconciliation through the public pure state owner. For
any bug discovered, first attempt reproduction through its production owner's
public pure reducer events, completions, state, and effects, as AGENTS.md requires.
If reproduced there, add only that pure regression test.

Reference resolution and recycling are executed by graph snapshot reads; merely
injecting an incorrectly resolved favorites response into a worker reducer does
not test that read. Verify these semantics at the narrowest public snapshot-read
boundary unless a production pure owner actually executes them. Do not duplicate
the same regression in runner, transport, persistence, integration, or UI tests.
Use existing application view tests for root selection, display-only row
composition, and Capture visibility. Use native inspection for gesture/layout
behavior that pure tests cannot establish.

## Risks

- The public overlay spec must change before the recommended graph read can be
  implemented. This is a concrete prerequisite, not an already supported API.
- Recycling through ancestors and link-only reorder transactions can escape an
  incomplete invalidation footprint. Prove their change propagation explicitly.
- Broadening Journal_model to allow fake/missing journal days would weaken
  unrelated validation. Keep favorite presentation separate from journal data.
- Static child summaries can turn a simple favorites list into many reads;
  enforce their bounded preview budget without adding expansion requests.
- Adding a page-detail route or in-app favorite add/remove/reorder controls would
  expand the requested feature. They are not part of the recommended first pass.
- A missing hidden page is proposed to be empty without mutation. Genuine read
  corruption must still produce an error, rather than disappear as an empty list.

## Consequences

Favorites reads fail explicitly above the 10,000-membership resource limit and do
not display child previews. Invalidation on every graph push is conservative:
large active lists may refresh for unrelated changes, while inactive lists only
become dirty. This keeps dependency tracking complete and subscription memory
constant. Graph replacement clears both destinations. Native adapters add a small
host presentation boundary, verified by native widget tests; graph, cache, draft,
and mutation ownership remains in OCaml.

## Questions

None. The user resolved the product questions on 2026-09-08:

- **List contents:** One row per favorite target, in favorite order.
- **Q1 — Row press behavior:** First-version Favorites rows do nothing when
  clicked. No expansion or page/block detail navigation is included.
- **Q2 — Capture on Favorites:** Do not display Capture on Favorites.

On 2026-09-08, the user requested transition to proposed. The protected-spec
interface prerequisite remains documented above; this lifecycle transition does
not authorize implementation or protected-file edits.


### Implementation authorization and verification

On 2026-09-08, the user explicitly authorized changes to
`logseq_overlay_db/spec/database.mli` and `logseq_overlay_db/spec/types.mli`
for this implementation. The dune and framework restrictions remain in force.

Verification proceeds through public snapshot reads, destination reducer events
and completions, protocol catalogs, application view tests, and native inspection.
Each implementation stage starts with failing behavioral coverage, then implements
the public contract, verifies passing behavior, and checks the affected suites.

The read implementation audit explicitly verifies link-only publication through
public authoritative completion and snapshot reads. It asserts that the logical
projection advances, the membership UUID is published, and an old cursor is
rejected. This passes with the existing graph publication owner. Favorites
conservatively invalidates on every logical graph push, including resync, so its
subscription footprint remains constant and covers filtered targets, ancestry,
restoration, and hidden-page discovery without a growing per-target watch list.

Native Capture uses an application-owned adapter around the existing Flutter FAB,
persistent bottom sheet, and MessageComposer. The existing expandable composer
has no draft initialization API; it cannot restore a draft after being removed
on Favorites. The adapter seeds its controller from application state and closes
the sheet on disposal. A persistent sheet keeps the NavigationBar reachable.
A graph-scoped native root owns two scroll controllers and restores membership
anchor offsets after refresh. No framework source is changed.


### Implementation outcome

The graph read scans at most 10,000 raw memberships, including malformed members,
with at most 200 scanned members per page and 256 ancestry steps per target.
Result sizes also obey the existing response budget. It returns resolved page and
block summaries without child previews or per-target subscriptions. Missing or
entirely filtered favorites is an empty read; resource, cursor, and storage
failures remain typed errors. The application reads 50 members per request and
keeps a rendered window of at most 128 rows.

Journals and Favorites share the existing root service and row renderer. Favorites
owns its lazy cache, refresh staging, request generations, and membership anchor.
Every graph push invalidates the cache; inactive reads remain isolated and graph
replacement discards both tab lifetimes. Capture draft/save state stays in the
application, while its native adapter owns only editing controls and sheet focus.

The public widget registry renders the OCaml NavigationBar descriptor using the
built-in Material NavigationBar. The installed Expressive renderer truncates wide
labels and gives compact selected labels the indicator foreground even outside
the indicator, which fails high-contrast dark presentation. The application host
uses the built-in component with a bounded navigation text scale and raw native
bottom safe inset. It does not introduce a custom tab strip or change framework
source. Main content retains the requested accessibility text scale. Shared rows
reclaim the unused timestamp/disclosure width for favorites. Tail fades use the
same Material theme package as the host, preserving the actual surface color.

Layout/color and native editor defects cannot be reproduced by the application's
pure reducer: native text constraints, theme lookup, TextEditingController, and
bottom-sheet disposal execute them. Their regressions use the existing native
layout or adapter boundary. Worker service failures likewise terminate outside the
Favorites reducer, before a protocol completion exists; the application dispatch
fixture verifies request correlation, retained rows, Retry, and recovery. Cache,
anchor, graph generation, draft, and save semantics are tested only through the
public pure owners. The snapshot-read fixture verifies actual reference resolution,
ancestor recycling, overlay title changes, link-only publication, cursor invalidation,
and raw malformed-member scan limits instead of injecting resolved results.

Native checks cover 20 Favorites layouts across light/dark, high contrast, RTL,
320/390/720-point widths, 3.2 text scaling, reduced motion, and bottom insets.
They assert label fit and contrast, no row activation or horizontal action, and
native destination selection events. Separate native checks cover retained scroll
offsets, refreshed anchor deltas, keyboard/composer layout, draft restoration, and
saved-text clearing. Header and Favorites frames are generated together so default
parallel Flutter tests do not race for the Dune build lock.


### Final verification

- `dune build @all` and `dune runtest`: passed.
- Formatting checks for the affected application, tests, overlay, and worker:
  passed. Existing unrelated reproduction documents were left unchanged.
- `python3 tool/test_macos_regressions.py`: all three registered cases passed.
- `flutter analyze`: passed with no issues.
- `flutter test --no-pub`: 103 passed, 7 existing opt-in/platform tests skipped;
  default parallel execution passed.
- `bonsai-flutter build macos --profile=debug`: produced the macOS Debug app.
- Favorites native PNGs were visually inspected at ordinary and enlarged RTL
  sizes; body width, navigation labels, contrast, surface fades, and bottom
  clearance were corrected and reverified.
- No dune file or bonsai_flutter OCaml source was modified. The only modified
  protected interfaces are the two explicitly authorized overlay `.mli` files.
