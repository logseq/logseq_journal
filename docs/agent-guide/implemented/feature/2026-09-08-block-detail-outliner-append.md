# Block Detail Outliner Append

## Problem

The existing block detail route opens directly in editing mode. Its page repeats
the root source above an editor, renders direct children as flat text, and uses
an inline `Add child` / `Save child` form. This makes it difficult to read a
block in its hierarchy and gives child creation a different interaction from
Capture.

Timeline currently uses block-row activation to expand children inside the
list, while Favorites rows are display-only. Neither provides the requested
consistent entry into the dedicated block detail page.

The requested experience is a dedicated block page with a back button at the
far left of its header, an outliner body, and an `append` FAB that creates a
direct child of the currently opened block using the Capture input UI.

## Proposal

The first version supports entry from Timeline and Favorites block rows,
reading, branch disclosure inside detail, append, and deletion. Timeline no
longer expands block trees inline. Inside detail, child content taps do
nothing, and a rightward swipe reveals only `Delete`. Editing existing blocks
is outside the first version, as clarified by the user on 2026-09-08.

### Entry from Timeline and Favorites

- Tapping a valid Timeline block row opens that block as the root of the
  dedicated detail page, whether or not it has children. The row's content and
  former disclosure target perform the same navigation; there is no separate
  in-list expand/collapse action or expandable-state accessibility hint.
- Tapping a Favorites block-target row opens the referenced block's detail
  page. Resolve the target block UUID from the favorite target, not the
  membership UUID used to identify and anchor the Favorites row. Navigation
  must also work for blocks outside the currently loaded timeline and for
  blocks on non-journal pages.
- Favorites can contain both page and block targets. This block-detail change
  applies to block targets; page-target rows retain their current behavior.
  Do not invent a corresponding block, open the membership record, or pick
  the first child of a favorite page. Page detail is outside this proposal.
- Give navigable rows normal tap feedback and an accessible `Open block`
  action. Timeline swipe actions still operate on their row and must not also
  navigate. Favorites list rows retain their existing no-swipe behavior; the
  right-swipe Delete action belongs to the detail outline.
- Record the originating destination, stable row identity, and scroll/focus
  anchor before loading detail. Back returns to Timeline or Favorites as
  appropriate, including from loading/error states. For Favorites, restore by
  membership identity even though detail is loaded by target block identity.
- Load detail from the current graph by block ID. Do not require first
  selecting Journals or finding the block in the timeline's retained window.
  If the target disappears before loading completes, show the existing
  unavailable detail state with Back. Correlate requests by graph and detail
  session so repeated taps and late results cannot replace another target.

### Remove Timeline inline tree expansion

- Remove the Timeline row's expand/collapse interaction, disclosure control,
  expansion state, child-loading effects, and inline expanded-child slots.
  This includes expansion-only loading/more rows and continuation handling.
  Remove the obsolete public actions and their callers instead of retaining
  a hidden toggle handler or compatibility mode.
- Keep journal/day pagination, ordinary block previews, and existing static
  child-summary text. A summary remains part of its parent row's tap target;
  it does not become a separately navigable or expandable child row.
- Tree disclosure and child pagination now belong to the detail outline.
  Returning to Timeline restores its list anchor without restoring or loading
  an inline tree. Keep shared graph read/mutation facilities still required by
  detail; only Timeline's expansion ownership and wiring are removed.

### Page and navigation

- Present detail as a separate full-page route above the originating page.
  Keep the header visible while the outline scrolls. Do not show the root
  Journals/Favorites navigation bar on detail.
- Put an icon back button at the physical far left of the header, including
  under RTL layout, as requested. Give it the accessible label `Back` and an
  adequate touch target. Use `Block` as the concise header title; show the root
  content once in the outline rather than copying it into the header.
- Enter in reading mode without opening the keyboard. Preserve the originating
  destination, scroll anchor, and focus target when returning.
- Use the same header for loading, failed-load, and unavailable-block states.
  Offer `Retry` on load failure; keep Back available. Disable append until the
  root is available and writes are allowed.
- Prefer existing Flutter Scaffold, AppBar, IconButton, scrolling, and FAB
  facilities exposed by the UI layer. Apply existing typography, spacing,
  safe-area, and reduced-motion tokens. Use no row dividers; the complete page
  must stay within the three-divider limit in `docs/ux-guidelines.md`.

### Outliner

- Render the currently opened block as the depth-zero root, followed by its
  children in stored sibling order. Show full wrapping content, including
  embedded newlines, without the timeline's three-line preview limit.
- Use indentation and a bullet/disclosure affordance to communicate hierarchy.
  Keep task status visible using the existing status vocabulary. Do not repeat
  collapsed child-summary snippets alongside real child rows.
- Initially expand the root and show its direct children. Start deeper branches
  collapsed. A disclosure control expands/collapses that branch in place;
  lazily load its direct children and support further levels the same way.
- Tapping child content performs no action: it neither opens another detail
  page, edits the block, nor toggles the branch. The separate disclosure
  control remains responsible for expansion. Do not add nested detail history.
- Keep expansion, loading, pagination, and retry state per parent. Retain the
  cursor from each child page and load continuation pages without treating the
  first page as the complete branch. Branch errors leave other content usable.
- Use one vertical scrolling surface for the visible outline. Keep identity
  stable by block ID, bound materialized rows, and preserve the visible anchor
  during branch updates. Deep indentation must leave usable text width;
  accessibility still exposes the actual level and expanded state.
- A root with no children remains a normal readable outline with append
  available. No large empty-state panel is needed.

Conceptual layout (illustrative text, not a new visual style):

```text
[Back]  Block

v Opened block, with its full content
    • First child
    > Second child with descendants
    • Third child

                                      [+ append]
```

### Append and Capture parity

- Place one extended FAB labeled exactly `append` in the page's bottom-end FAB
  slot, with the same add icon and visual treatment as Capture. Keep its label
  visible in this initial design and reserve enough bottom space for the last
  outline row to remain reachable.
- Pressing append opens the same
  `Ui.Native_widget.Expandable_message_composer` used by Capture. Reuse its
  modal bottom sheet, animation, autofocus, keyboard/safe-area response,
  multiline growth, surface styling, task toggle, and submit icon. The FAB
  disappears while the sheet is open. The hint can read `Append a child` and
  the submit tooltip `Save child block` to identify the destination.
- Keep native dismissal and draft lifetime consistent with current Capture.
  Dismissing does not submit; do not promise draft restoration after the route
  or composer is removed. Platform Back first follows the existing keyboard
  and modal dismissal behavior before popping the detail page.
- The append target is always the block that roots the current detail page.
  Expanding, focusing, or scrolling to a descendant does not change that target.
  For root A and descendant B, append creates a direct child of A even when B
  is expanded. Child drill-in is not supported.
- A submission creates exactly one new block at the end of the root's direct
  children. Multiline input remains one block, and the task toggle has the
  same meaning as Capture. It must not create a journal-level entry or append
  under the last visible child. Resolve the end against the complete sibling
  sequence even when only some children have been loaded.
- Use the existing child mutation, identity, order-allocation, write-admission,
  and retry mechanisms. Disable duplicate submission while saving. A rejected
  write must expose a recoverable error and must not be shown as successful;
  retries must not create duplicate children or change their parent.
- After confirmed local creation, remain on the same detail page in reading
  mode, reset the composer using the existing Capture success lifecycle, and
  reconcile the new child and parent count. Reveal the new child without
  discarding loaded branches, and update the originating list's projection.
  Do not return to root-source editing automatically.
- Share the composer construction/configuration between Capture and append,
  with explicit event routing and separate draft/session ownership. Remove the
  obsolete inline child editor and its actions when implementing this design.
  Do not retain a second input UI or a compatibility path.

### Row swipe actions

- Every block row in the outline, including the root and visible descendants,
  supports a physical rightward swipe to reveal only `Delete`.
  Reuse the timeline row's Slidable component, reveal motion, action sizing,
  icon/label treatment, destructive Delete palette, and single-open-row
  behavior. Place Delete in the detail row's right-swipe pane regardless of
  its side in the timeline. Preserve that physical gesture under RTL and
  expose an accessible Delete action.
- Swiping only reveals Delete; it must not delete automatically, even on a
  full swipe. Close the action pane when Delete is selected.
- Do not expose an Edit action, disabled Edit placeholder, root editor, or
  prefilled editing sheet in this version. Existing block content is read-only.

### Delete behavior

- `Delete` targets the swiped block and its descendants, using the existing
  `Delete_subtree` semantics. Apply the timeline's staged deletion, Undo window
  (including its accessibility duration), and failure restoration behavior.
  Do not add an extra confirmation dialog for the same action.
- Deleting a descendant removes its visible subtree, updates affected counts,
  and keeps the current root page open. Undo restores the branch and relevant
  expansion state; a failed delete restores the affected data with feedback.
- When the opened root is staged for deletion, return to the originating page
  with the same Undo feedback. Undo restores the block there without opening
  another detail page. Root deletion failure also restores it there.
- Respect existing write admission and pending-operation guards for append
  and deletion. Undo or failure recovery must reconcile current data rather
  than replace unrelated changes with an old whole-outline snapshot.

### Scope

This iteration covers Timeline/Favorites block-row navigation, removal of
Timeline inline trees, detail tree reading/disclosure, append, and per-row swipe
delete inside detail. Editing existing blocks, detail-to-child navigation,
favorite page detail, inline row editors,
dragging, reparenting, sibling insertion, bulk operations, and a complete
keyboard-driven outline editor are outside this proposal. The former
always-visible root editor and inline child editor are replaced, without
compatibility paths.

### Production ownership and implementation seams

- `app/application.ml`: currently calls `Journal_detail.begin_edit` after a
  detail load and after child creation. It owns page composition, native event
  routing, and mutation dispatch. Replace those automatic editing transitions,
  rebuild the page layout, and share composer configuration and row action
  dispatch here. Route deletion by the swiped block ID, not the detail root.
  Wire Timeline and Favorites activation to detail loading, remove
  `timeline-toggle-children:` handling and its callbacks, and resolve Favorites
  navigation targets before reducing them to display-only row items.
- `app/journal_detail.ml` and `.mli`: own the root, direct children, editing,
  and child submission. The current state drops the child-page continuation
  and has no recursive branch state or public child-task-toggle operation.
  Extend the application-owned public state/event boundary for branch loading,
  append task intent, staged subtree deletion/Undo, and correlated operation
  completions before wiring the new UI. Remove obsolete detail editing modes
  and actions instead of retaining an unused editing path.
- `app/journal_routes.ml` and `.mli`: own detail identity and return behavior.
  Keep one detail above the originating page; child taps inside detail
  introduce no route transitions. Explicitly retain origin destination and
  destination-specific anchor identity for Back and root deletion.
- `app/journal_graph_request.mli` and `app/journal_graph_projection.mli` already
  expose `Load_detail` with a block ID and cursor, paged direct children,
  `Create_child` with a parent ID/revision, and `Delete_subtree`. Reuse these
  contracts and inspect completion correlation and invalidation before
  supporting multiple branches and row mutations.
- `app/journal_row.ml` and `app/journal_timeline_state.ml` provide existing
  hierarchy/status patterns, but their bounded preview text and row extents
  are not a full-content detail rendering contract. Do not copy those clipping
  assumptions into detail. `app/journal_timeline.ml` owns the Slidable action
  composition to reuse, while application pending-delete state owns the
  timeline's Undo deadline and mutation dispatch.
  Replace list-row `Toggle_children` interaction with block activation, retaining
  display-only rendering for non-block Favorites targets. Remove Timeline's
  expansion-only `Children` requests and `Child_preview`, `Children_loading`,
  and `Children_more` slots together with their state and rendering paths.
  Adapt preview geometry to the remaining static rows; keep feed/day paging.
- `app/journal_graph_runtime.ml`: current `Load_detail` reads a block but then
  requires its page to be retained by the journal runtime. Favorites entry must
  resolve the actual owning page through public graph reads when it is not
  retained. `app/journal_model.mli` currently requires `journal_day`; make
  detail's application-owned representation support real non-journal context
  without fabricated dates or weakening journal-feed validation. This is an
  implementation seam within the app, not a reason to reject valid favorite
  block targets or to bypass protected graph specifications.
- The current Capture reference is
  `docs/agent-guide/implemented/bugfix/2026-09-08-restore-expandable-capture.md`.
  It explicitly accepts modal navigation blocking and native draft lifetime.
  Reuse the restored component rather than reviving its removed adapter.
- This proposal supersedes the display-only block-target click behavior in
  `docs/agent-guide/implemented/feature/2026-09-08-journals-favorites-navigation.md`
  and Timeline's inline tree expansion. Their other list presentation and
  navigation behavior is not changed by this entry-point decision.

These are investigation and ownership boundaries, not authorization to modify
framework/spec files. Implementation must not modify dune files, OCaml files
under `spec/`, or OCaml files in bonsai_flutter. If required framework contracts
cannot express the design, stop and report the exact `.mli` issue, recommended
change, and rationale before proceeding.

## Decision

Advance this design to proposed at the user's request on 2026-09-08. The
first-version scope is a dedicated outliner page with a far-left Back button,
Capture-style append to the opened root, and right-swipe Delete on block rows.
Timeline and Favorites block-row taps open the corresponding detail root;
Timeline inline tree expansion is removed. Child content taps inside detail
do nothing, and editing existing blocks is deferred.
All interaction questions have been answered. Implementation and its
verification remain pending; this transition changes documentation only.

## Alternatives considered

### Detail as a bottom sheet

Not selected because the user requests an independent page and the outline
needs a stable reading surface. The bottom sheet serves append input.

### Keep the flat child list and inline Add child editor

Not selected because it provides neither recursive outline navigation nor
Capture parity. The old child-creation presentation should be removed.

### Eagerly expand the complete subtree

Not selected because a large subtree can overwhelm both the reading experience
and loading work. Expand the root first and load deeper branches on demand.

### Make append follow the selected row

Not selected because selection would silently change the insertion parent.
The opened page root provides the unambiguous target requested by the user.

### Open child details or edit content on tap

Rejected for rows inside the detail outline. Their child content taps do
nothing; disclosure is separate. Timeline and Favorites block-row taps open
detail as specified above. Editing existing blocks is outside the first version.

### Keep Timeline tree expansion alongside detail navigation

Not selected because the user explicitly removed Timeline's click-to-expand
behavior. Tree exploration belongs to detail, and list-row activation opens it.

### Include Edit in the first version

Deferred by the user. Do not implement prefilled editing sheets, per-row edit
sessions, or composer API extensions for editing as part of this version.

## Acceptance criteria

- Tapping a Timeline block row with or without children opens that exact
  block's detail page. No Timeline tap target expands/collapses a tree, and
  no expansion-only request, state, or inline child slot remains in Timeline.
- Tapping a Favorites block-target row opens its target UUID, never the
  membership UUID. This works for targets outside the retained timeline and
  on non-journal pages. Favorite page-target rows keep their existing behavior.
- Back from detail, loading, or failure restores the originating destination
  and row/scroll anchor, including a Favorites membership anchor after refresh.
  Deleted targets show an unavailable state; stale completions cannot navigate
  to another block or graph.
- Timeline swipe actions do not trigger navigation. Favorites list rows gain
  block activation without swipe actions. Timeline journal/day pagination and
  static child summaries remain functional without inline tree loading.
- Opening a block shows its dedicated reading page with a far-left header Back
  control and no automatically focused source editor.
- The outline displays the root once, full multiline text, ordered children,
  and independently expandable deeper branches. Pagination does not omit or
  duplicate children; expanding a branch preserves the visible anchor.
- Tapping child content inside detail has no effect on route, editor, or expansion. Only
  the disclosure control toggles a branch; no child detail history is created.
- Right-swiping any visible block row reveals only `Delete` in the timeline
  action style. A full swipe does not execute deletion. No Edit entry point
  or editing sheet is available for the root or descendants.
- Delete removes the selected subtree with the timeline Undo behavior.
  Descendant deletion keeps detail open; root deletion returns to the origin.
  Undo/failure restores affected data without discarding unrelated updates.
- The only child-creation entry point on detail is the `append` FAB. Its open
  input interaction matches current Capture in light/dark themes, large text,
  reduced motion, keyboard appearance, safe areas, and dismissal behavior.
- Appending while a descendant is expanded still creates one last direct child
  of the page root, including when that root's children span multiple pages.
  Empty input cannot submit; task intent matches Capture; repeated submit or
  retry does not duplicate the child.
- Successful creation returns to the readable outline on the same page,
  reveals the child, updates the root count and originating projection, and
  does not switch the root into editing mode.
- Loading, failure, unavailable-root, and write-disabled states have clear
  behavior; late completions cannot update another graph or detail session.
- Returning restores the originating destination/anchor.
- The final page uses existing visual tokens, built-in components where
  available, reachable controls, meaningful accessibility labels, and no more
  than three dividers. No obsolete inline root or child editor remains.

### Verification approach

Verify Timeline/Favorites row activation, favorite target versus membership
identity, origin restoration, detail request completions, and removal of
Timeline expansion effects through the owning public state/reducer interfaces.
Verify owning-page resolution for favorite blocks outside the retained journal
cache through the narrow public production boundary that executes that read;
do not inject a resolved detail result to claim coverage of page resolution.
Update tests for the retired Timeline expansion and Favorites block-row no-op
contracts to exercise the new navigation behavior at their existing ownership
boundaries, while retaining unrelated pagination, swipe, and graph-read coverage.

Verify detail branch events, pagination completions, append parent identity, ordering,
duplicate admission, subtree delete/Undo events and deadlines, and return
state through their production public pure
state/reducer interfaces. Exercise real public order-allocation behavior for a
partially loaded sibling list rather than injecting an already correct order.
Use the native widget boundary only for layout, swipe actions, focus, sheet
lifecycle, and Capture parity that pure state cannot observe. For any regression
discovered during implementation, first reproduce it through its production owner's public
pure events/state/effects and follow the repository's narrowest-layer rule.
Do not add redundant coverage across reducer, transport, and UI layers.

## Risks

- Favorites row identity is a membership UUID while detail identity is a target
  block UUID. Confusing them can load the wrong entity or restore the wrong row.
- Current detail loading assumes retained journal page metadata. Loading valid
  favorite blocks needs explicit owning-page resolution and a detail model
  that can represent non-journal blocks without fake journal dates.
- Removing Timeline child slots changes list geometry and anchor reconciliation.
  Keep day/feed continuation and static previews correct while removing all
  expansion-only paths.
- Recursive branch paging and full-content row heights need more state and
  rendering support than the current flat detail view. Framework capability
  must be checked before promising a particular virtualization strategy.
- Native composer lifecycle is partly owned by Flutter. Visual parity alone
  does not establish correct child targeting, retry behavior, or stale-event
  rejection in application state.
- Concurrent changes may delete/move the parent or invalidate sibling cursors
  during append. Use existing revision/admission outcomes and reconcile the
  branch; never silently redirect the write to a different parent.
- Swipe-only Delete needs an accessible action equivalent and must
  remain distinguishable from disclosure and vertical scrolling.
- Descendant deletion adds mutation targets beyond the page root. Completion
  correlation and localized Undo restoration are required to
  avoid changing another row or discarding unrelated branch updates.

## Questions

None outstanding for the first-version block-detail interaction decisions.
Timeline and Favorites block-row taps open the corresponding detail page;
Timeline no longer expands block trees inline. Child content taps inside detail
do nothing, and editing existing blocks is deferred. Right-swiping a detail
block reveals only Delete; append reuses Capture's input UI to create a direct
child of the opened root. Favorites page targets remain outside block-detail
navigation scope.

The previously identified composer prefill/external-open capability gap belongs
to deferred editing and is not a dependency of this version.


## Implementation and verification

Implemented on 2026-09-08. `Journal_routes` owns target identity, originating
destination and membership/row anchors. `Journal_detail` owns the outline,
per-parent requests and cursors, append admission and completion correlation,
materialized windows (at most 40 product rows), and localized subtree Undo.
`Journal_graph_runtime` resolves actual owning-page metadata, including ordinary
pages, and submits append through the existing public `V2_insert_blocks` tail
allocator. Timeline expansion slots, requests, state and rendering parameters
have been removed.

The application supplies all product rows and actions from OCaml. The small
`journal_detail_outline.dart` native adapter owns measured variable-height list
geometry, visible-range reporting, anchor restoration, reveal scrolling and
accessible custom actions. It uses Flutter's `ListView.builder`, `AppBar` and
existing Slidable host. Capture and append call the same composer constructor
with separate state and keys. Append admission is published before dispatching
its effect, so immediate responses cannot be overwritten by Saving state.

### Automated checks

- `dune build @all` and `dune runtest` passed.
- 170 Flutter tests passed across the outline adapter, root navigation, header
  layout, tail fade, macOS Edit menu, application host, worker host and widget
  suites, using `bonsai-flutter exec --profile=debug`.
- The existing public overlay mutation case `append uses tail beyond first
  page` passed explicitly: its real allocator appends after 230 existing
  siblings despite reading only the first page. This coverage was reused
  rather than duplicated with an injected child order.
- `bonsai-flutter build macos --profile=debug` produced the native macOS app.
- Pure route/detail tests cover stale and wrong-root responses, Favorites
  target versus membership identity, return anchors, independent branches,
  pagination order after append, duplicate admission, retry identity,
  correlated failures, subtree Undo, and bounded materialization.

Regression ownership was checked before adding cases. Wrong-root response
acceptance, append/continuation ordering, and loss of an appended child across
Undo plus cursor restart reproduced through the public route/detail state
interfaces; regression coverage remains only there. Owning-page resolution
is tested through public runtime request/response transitions, which actually
perform the missing page read. Native kind registration collisions cannot be
reproduced in those reducers; their narrow regression is registry construction.
Native viewport geometry is tested only in the adapter. The macOS continuous
append reproduction exercises application effect scheduling, which the detail
reducer does not own; its final check was repeated in the actual application.
Retired Timeline-expansion assertions were replaced by static-row/navigation
checks while retaining day/feed pagination, swipe and graph-read coverage.

### Actual macOS acceptance

Launched the built Debug application and verified warm start into the most
recent graph. Used a uniquely named test root created through Capture to check:

- A leaf opens a read-only Block page with Back at the physical left, no
  automatically focused editor and no root navigation bar.
- The append sheet matches Capture; empty input has no submit action.
  A multiline Todo child persists with task intent and exact line breaks.
- Expanding a child and submitting additional appends produces ordered direct
  children of the root. Continuous submissions return to the readable outline
  and reveal the new child. Child content taps do not navigate or expand.
- A full rightward swipe reveals only Delete without executing it. Deleting
  a child retains detail; immediate Undo restores it. Deleting the root
  returns to Timeline; Undo restores the test root and its subtree.
- Existing Favorites block targets open their own outline, deeper disclosure
  reveals level-three children, and Back returns to Favorites in place.
  Existing user blocks were read only.

The final build was relaunched to confirm persistence of all three appended
children. The dedicated test root and its children were then deleted through
the application, and the completed deletion was verified on Timeline.

No dune files, protected `spec/` OCaml files, or bonsai_flutter repository
OCaml files were modified.


## Consequences

Timeline and Favorites block rows now share one read-only detail destination.
Tree expansion state is owned exclusively by that detail session; returning
to either list preserves its separate state. Ordinary-page metadata is a
first-class input to block projection, without synthetic journal dates.

Variable-height outlines require one mechanical native viewport adapter while
all graph operations and product decisions remain in OCaml. Existing-block
editing remains outside this feature. The old detail editors and Timeline
expansion APIs have been removed rather than retained as alternate paths.
