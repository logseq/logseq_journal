# Journal UI/UX Redesign Implementation Plan

Goal: Replace the obsolete journal presentation with the quiet mail-inspired feed, drawer, inline Block card, route composition, system states, responsive behavior, and accessibility contract defined in `003-journal-ui-ux-redesign.md` without changing persistence or Worker behavior.

Architecture: OCaml/Bonsai continues to own application state, routes, handlers, semantics, theme selection, and the declarative widget tree in `app/application.ml`.
The implementation composes existing typed `bonsai_flutter` widgets and native widgets, while `Sparse_extent_list`, `Morphing_surface`, and `Navigation_shell` retain their current renderer-local ownership and stable identity contracts.
No file under `spec/`, no Dune file, and no Flutter host file is changed by this plan.

Tech Stack: OCaml 5.1, Bonsai, `bonsai_flutter.ui`, `bonsai_flutter.driver`, `bonsai_flutter_test`, Dune, Flutter renderer integration, and repository-local Mail example patterns.

Related: Builds on `docs/agent-guide/003-journal-ui-ux-redesign.md` and `docs/agent-guide/002-journal-rewrite.md`.

## Problem statement

The journal already has durable storage, bounded Worker projections, stable routes, one-open preview state, revisioned editors, recovery behavior, environment awareness, and a sparse retained feed.

The current widget tree does not express those capabilities with a coherent hierarchy.
It uses a standard root AppBar above a separate Search action, an undiscoverable and nearly empty drawer, duplicate Block actions, plain preview lines, repeated route titles, generic lifecycle text, and default component styling.

The implementation must replace that obsolete presentation rather than preserve it beside the redesign.
Behavioral ownership, request fencing, durable confirmation, list identity, route restoration, and bounded data limits must remain unchanged.

The current worktree is intentionally the implementation baseline even when it differs from the historical commit named in the design document.
Before every batch, inspect the worktree and preserve unrelated user changes.

## Scope and file boundaries

| Purpose | Path | Allowed change |
| --- | --- | --- |
| Application rendering and UI handlers | `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` | Replace obsolete presentation and add view-local helpers or handlers. |
| Public application contract | `/Users/rcmerci/gh-repos/logseq_journal/app/application.mli` | Do not change unless implementation exposes a genuinely required application-owned type or function. |
| End-to-end Bonsai UI behavior | `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml` | Replace obsolete expectations and add user-observable redesign coverage. |
| Design authority | `/Users/rcmerci/gh-repos/logseq_journal/docs/agent-guide/003-journal-ui-ux-redesign.md` | Read only during implementation. |
| Reference composition | `/Users/rcmerci/gh-repos/bonsai_flutter/examples/mail/ocaml/mail.ml` | Read only and translate patterns without copying mail behavior or branding. |

The implementation must not modify any OCaml file under `/Users/rcmerci/gh-repos/logseq_journal/spec/`.

The implementation must not modify `/Users/rcmerci/gh-repos/logseq_journal/app/dune`, `/Users/rcmerci/gh-repos/logseq_journal/test/dune`, `/Users/rcmerci/gh-repos/logseq_journal/dune-project`, or any other Dune file.

The implementation must not modify `/Users/rcmerci/gh-repos/logseq_journal/flutter/`.
If an existing typed widget cannot express a required design, stop and report the exact generic API gap instead of introducing app-specific renderer code.

## Existing behavior that must remain authoritative

| Invariant | Existing evidence |
| --- | --- |
| Durable capture, task update, parent edit, and child creation | End-to-end cases in `test/feed_app_test.ml`. |
| One open preview with stable feed identity | `preview_state`, `block_widget`, sparse extent overrides, and preview tests. |
| Bounded feed rendering and continuation | `ready_feed`, mounted slot data, and sparse feed tests. |
| Revisioned Search with debounce and stale response fencing | `search_state`, Search handlers, and Search tests. |
| Dirty draft and editor pop protection | Capture, Detail Edit, Add Child state and route tests. |
| Recovery-only mutation removal | `access_mode` checks and recovery tests. |
| Settled drawer state synchronization | `drawer_open`, `Navigation_shell`, and drawer native-event test. |
| Environment-selected motion and theme | `layout_profile`, `semantic_theme`, and accessibility tests. |

## Target composition

```text
Theme
└── Navigator
    ├── Feed page without a standard AppBar
    │   └── centered width constraint, max 720
    │       └── Navigation_shell
    │           ├── functional drawer
    │           └── feed body
    │               ├── rounded 56-pixel header
    │               ├── page context or lifecycle banner
    │               ├── rounded sparse feed surface
    │               └── lower-trailing New entry overlay
    └── one optional Slide route
        ├── Capture compose page
        ├── Search page with bounded scrolling results
        └── Block Detail page with optional route-local editor
```

## Testing Plan

All UI changes are verified through the real Bonsai application component and real Worker-backed repository fixtures in `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.
Tests must click rendered controls, dispatch native widget events, edit revisioned text fields, pump effects, inspect observable semantics and layout props, and assert persisted data where mutation behavior is involved.

The RED phase replaces assertions that describe the obsolete hierarchy and adds all tests for the selected implementation batch before application behavior changes.
Each test must fail for an expected missing redesign behavior, such as a missing header, duplicate compact action, incorrect route shell, absent status composition, or incorrect environment token.
A compilation error, missing fixture, or malformed query is not an acceptable RED result.

The GREEN phase changes only `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` unless a public signature change is proven necessary.
Existing Worker, repository, storage, and feed-state tests remain regression gates throughout.

Manual visual QA uses the existing Flutter host after automated tests pass.
The QA pass must cover the matrix in `003-journal-ui-ux-redesign.md` and record any unresolved tuning question before the goal is declared complete.

NOTE: I will write *all* tests before I add any implementation behavior.

## Requirement-to-evidence matrix

| Requirement | Automated evidence | Manual evidence |
| --- | --- | --- |
| Tonal root shell and rounded feed composition | Widget tree decoration, width, inset, and absence-of-old-AppBar assertions. | Compact light, compact dark, and wide captures. |
| Functional header and truthful drawer | Control-click, drawer-state, route, selection, and recovery-status assertions. | Drawer scrim, alignment, and reachability review. |
| Compact Block anatomy | Action isolation, semantics, target size, ellipsis, and obsolete-control absence assertions. | Dense scan-path and press-feedback review. |
| Expanded outliner card | One-open behavior, stable list index, preview bounds, footer route behavior, extent, and semantics assertions. | Connector alignment and smallest-device footer reachability review. |
| Capture composition | Toolbar, date context, Save state, feedback, discard, persistence, and safe-area assertions. | Keyboard, editor height, and lower-trailing action review. |
| Search composition | Toolbar, clear, debounce, result grouping, bounded scrolling, state, and navigation assertions. | Fifty-result compact viewport review. |
| Detail and editors | Toolbar, primary surface, children, recovery action removal, editor, conflict, and pop assertions. | Long-content and nested editor review. |
| Lifecycle and accessibility | Live-region, heading, focus-order proxy, target, contrast-profile, and reduced-motion assertions. | High contrast, invert colors, text scale, and screen-reader review. |

## Phase 1: Establish the complete RED suite

Use `@Test-Driven Development (TDD)` for this phase and every later implementation phase.

### Task 1: Add reusable behavior assertions

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.

Steps:

1. Add query helpers that require a widget kind, semantics role, test ID presence or absence, fixed extent, padding, decoration radius, alignment, enabled state, and child count only when those properties represent user-observable UI behavior.
2. Add helpers that find all matching semantic buttons so duplicate actions can be detected rather than hidden by a first-match query.
3. Add a helper that asserts a route uses a Body vertical fill slot for scrolling content.
4. Add a helper that reads theme brightness and seed behavior without coupling the test to private application data structures.
5. Run `dune exec test/feed_app_test.exe` from `/Users/rcmerci/gh-repos/logseq_journal`.
6. Confirm the unchanged behavior suite still passes before changing expectations.

Expected result: The helper-only change compiles and the existing test executable exits successfully.

### Task 2: Replace obsolete shell and compact-row expectations

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.

Steps:

1. Replace `test_feed_shell_has_only_working_destinations_and_bounded_capture_layer` with assertions for a root page without a standard AppBar, a `journal-header`, `journal-menu`, `journal-search`, `journal-quick-capture`, and lower-trailing `journal-capture` control.
2. Assert the header is 56 pixels high, has a 28-pixel radius, and remains inside the centered 720-pixel content column.
3. Assert the feed surface is rounded and the feed bottom inset includes the lower-trailing action footprint plus safe area.
4. Replace `test_compact_block_actions_share_one_horizontal_band` with a test that observes one leading task checkbox, one pressable main/disclosure region, metadata, and one trailing disclosure target.
5. Assert `block-open:<id>`, `block-more:<id>`, `block-task:<id>`, and the duplicate text task action are absent while the compact row is collapsed.
6. Click the task checkbox and prove it changes task state without opening preview or Detail.
7. Click the main Block target and prove it opens preview without changing task state or navigating.
8. Add non-task coverage proving the leading bullet is not a semantic button.

Expected RED result: Assertions fail because the current root AppBar, Search row, centered Capture action, and duplicate Block controls are still rendered.

### Task 3: Add drawer and lifecycle shell tests

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.

Steps:

1. Click `journal-menu` and assert `Navigation_shell` receives an open target state.
2. Assert the drawer renders `Logseq Journal`, selected `Today`, functional `Search`, and a non-interactive `Local data` status with either `Read-write` or `Recovery only`.
3. Click drawer Search and assert the drawer closes before the Search route becomes the top page.
4. Simulate an open drawer and platform Back, then prove the drawer is consumed before route Back.
5. Exercise Opening, Loading, Empty, Recovery only, Mutation locked, and Terminal fixtures and assert they retain the same header and root shell.
6. Assert only states with an implemented recovery action expose a Retry button.
7. Assert recovery-only states contain no Capture, Add Child, Edit, or task mutation controls.

Expected RED result: Tests fail because there is no visible Menu action, the drawer contains only plain `Today`, and lifecycle views are plain body rows.

### Task 4: Add expanded card tests

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.

Steps:

1. Expand a Block with depth-two descendants and assert the card retains `block:<id>` and the same sparse-list index.
2. Assert the header retains the compact anatomy and exposes explicit expanded semantics.
3. Assert descendant nodes appear in source order with level-aware labels, one-line presentation, and decorative connector elements excluded from semantics.
4. Seed more than eight or deeper-than-two descendants and prove only the bounded preview appears with one `More descendants…` announcement.
5. Assert equal `block-add-child:<id>` and `block-open:<id>` footer actions have minimum 48-pixel height.
6. Click Add Child and assert Detail opens with the child editor active.
7. Click Open and assert normal Detail opens without an editor.
8. In recovery-only mode, assert preview and Open remain while Add Child and task mutation are absent.
9. Assert regular and large-text expanded extent overrides are deterministic and reduced motion resolves with a disabled transition.

Expected RED result: Tests fail because the current preview has plain lines, no footer, and Open is exposed in both compact and expanded presentations.

### Task 5: Add Capture route tests

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.

Steps:

1. Open Capture from both entry points and prove both create the same route behavior.
2. Assert the page has no standard AppBar and contains one compact toolbar with Cancel, `New entry`, and Save.
3. Assert localized observed-day context appears once above the editor.
4. Assert Save is disabled for trimmed blank content and during an accepted pending save.
5. Assert the editor receives remaining vertical space and retains the 65,536 UTF-8 byte limit.
6. Assert validation, queue-busy, Worker-not-ready, Saving, conflict, and content-limit messages share one inline status region.
7. Assert clean Cancel closes immediately and dirty Cancel exposes only `Keep editing` and destructive `Discard` in an inline confirmation surface.
8. Assert platform Back remains blocked while the editor, discard decision, or save is unresolved.
9. Preserve the durable confirmation test and change its visible success expectation to `Entry saved` with optional `Added to today` support text and Show action.

Expected RED result: Tests fail because the current Capture page repeats AppBar and body titles and uses a static stacked Column.

### Task 6: Add Search route tests

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.

Steps:

1. Assert Search has no standard AppBar and renders a single toolbar containing Back, the revisioned field, and Clear.
2. Enter a query, click Clear, and prove the existing pending generation is fenced while the route returns to prompt state.
3. Assert prompt, searching, empty, partial, and failed states use distinct semantics and only expose Continue or Retry when backed by a real handler.
4. Seed results on multiple days and assert stable keyed result rows show day context, snippet, and disclosure in source order.
5. Assert Block results navigate to Detail and page-only results are not semantic buttons.
6. Seed the 50-result cap and prove results live in a bounded vertical fill or sparse viewport rather than an unbounded static Column.
7. Retain the 250-millisecond debounce, Unicode normalization, scalar limit, automatic continuation, result cap, and stale-response assertions.

Expected RED result: Tests fail because the current Search route repeats labels, lacks Clear, and appends results to a static Column.

### Task 7: Add Detail and shared editor tests

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.

Steps:

1. Assert loading and ready Detail pages share a custom compact toolbar and tonal page shell without a standard AppBar.
2. Assert ready Detail contains a full-content primary Block surface, truthful task and child metadata, a Children section, and one contextual Add Child action.
3. Assert Edit exists only in the toolbar and the old duplicated `More children…` text is absent when no continuation handler exists.
4. Assert writable task state can change independently from Detail navigation or editor state.
5. Assert Edit replaces the primary surface and Add Child inserts a visually nested editor below the root Block.
6. Assert both editors share Save, Cancel, validation, saving, conflict, Keep Editing, and Discard language with Capture.
7. Assert conflict keeps the user draft, shows latest saved content once, and announces `This Block changed` without duplicating full content in live-region semantics.
8. Assert recovery-only Detail preserves reading and children but omits Edit, Add Child, and task mutation.
9. Retain durable edit, durable child creation, dirty discard, stable route key, and platform Back regression coverage.

Expected RED result: Tests fail because current Detail uses a standard AppBar and a plain static Column with competing text actions.

### Task 8: Add visual-system, responsive, and accessibility tests

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.

Steps:

1. Assert regular compact row extent is 88 pixels and large-text extent is 104 pixels.
2. Assert the transition uses 220 milliseconds for expansion, 190 to 220 milliseconds for collapse, `Ease_out_cubic` expansion, and a permitted collapse curve.
3. Assert reduced motion, disabled animations, and accessible navigation disable geometry interpolation without removing controls or semantics.
4. Assert light, dark, high-contrast, and invert-color environments select distinct semantic theme outputs.
5. Assert header, feed, banners, cards, and route surfaces receive the intended semantic color roles rather than default styling.
6. Assert all named controls have explicit button semantics and at least 48 by 48 pixel targets.
7. Assert day headings remain level two, route titles are level one where supported, and decorative bullets, dividers, and connectors are excluded from semantics.
8. Assert compact insets start at 12 pixels, regular insets use 20 to 24 pixels, and content remains capped at 720 pixels.
9. Assert the Capture overlay is lower-trailing and cannot cover the final reachable feed row at each safe-area profile.

Expected RED result: Tests fail on large-text extent, root decorations, route semantics, responsive insets, and lower-trailing Capture alignment.

### Task 9: Verify the RED phase is valid

Files:

- Inspect `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml`.
- Do not modify application implementation files in this task.

Steps:

1. Run each new test independently with the existing environment-variable selectors or add redesign-specific selectors inside the test executable.
2. Run `dune exec test/feed_app_test.exe` from `/Users/rcmerci/gh-repos/logseq_journal`.
3. Record every failing test name and expected assertion in the implementation log or checkpoint report.
4. Fix test compilation, fixture, and query errors until failures are exclusively caused by missing redesign behavior.
5. Confirm all persistence, Worker, feed-state, and repository tests remain untouched.

Expected result: The complete redesign suite is RED for expected behavioral reasons and existing non-redesign tests still pass when selected independently.

## Phase 2: Implement application tokens and reusable view primitives

### Task 10: Add semantic visual tokens

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Add an application-local token record selected from `Environment.snapshot` for background, primary surface, raised surface, primary, primary container, primary text, secondary text, outline, success, and error roles.
2. Add explicit normal light and normal dark values from the design document.
3. Add dedicated high-contrast and invert-color selections rather than reusing normal light tokens.
4. Keep `semantic_theme` as the Material component theme and make its brightness and seed agree with the selected application tokens.
5. Add small helpers for styled text, symmetric padding, Material icons, tonal decoration, semantic icon buttons, dividers, and status surfaces.
6. Avoid state, routing, or Worker changes in these helpers.
7. Run the visual-system tests and confirm the token and typography assertions pass.

Expected GREEN result: Environment changes select coherent tokens and existing behavior remains unchanged.

### Task 11: Refactor shared status and toolbar components

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Replace plain notice rows with one reusable tonal banner helper accepting icon, title, supporting text, optional action, tone, and live-region policy.
2. Add a compact route toolbar helper that supports Back or Cancel, a semantic level-one title, and one trailing action.
3. Add a shared editor status helper for saving, validation, queue rejection, Worker readiness, content limit, conflict, and discard confirmation.
4. Ensure live regions announce state changes only and never duplicate full Block or draft content.
5. Run focused lifecycle, editor, and semantics tests.

Expected GREEN result: Shared presentation primitives pass behavior tests without moving application state across ownership boundaries.

## Phase 3: Implement the root shell and drawer

### Task 12: Replace the root AppBar with the journal header

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Add an `open_drawer` Bonsai handler that commits the drawer target state in OCaml.
2. Render a 56-pixel rounded header with a 48-pixel Menu target, flexible Search target, and 48-pixel quick Capture target.
3. Render quick Capture only when Capture is valid for the current access and lifecycle state.
4. Remove the root `Ui.Material.app_bar` and place the safe-area-aware header inside the feed page body.
5. Add responsive 12-pixel compact and 20-to-24-pixel regular outer insets while retaining the centered 720-pixel maximum width.
6. Place feed content inside a rounded primary surface.
7. Change the extended action label to `New entry`, align it lower-trailing, and derive feed bottom inset from its footprint plus safe area.
8. Run shell, safe-area, responsive, route, and Capture-entry tests.

Expected GREEN result: The feed uses one quiet header and one rounded content hierarchy with no duplicated AppBar/Search chrome.

### Task 13: Make the drawer truthful and functional

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Add handlers for Today and drawer Search that first target the drawer closed state.
2. Make Today retain the feed model, clear route-only state, collapse no unrelated preview, and return the retained feed window to the top through the existing list state contract.
3. Make Search close the drawer and open the existing Search route.
4. Render product header, selected Today row, Search row, and non-interactive Local data status.
5. Render the current recovery warning in the drawer when applicable.
6. Do not add Settings, Tasks, Favorites, graph switching, or any placeholder destination.
7. Preserve settled native drawer-state synchronization and local Back, Escape, scrim, and edge-gesture ownership.
8. Run drawer, Back, route, recovery, and bounded-feed tests.

Expected GREEN result: The visible Menu target opens a drawer whose every interactive item has a real transition.

## Phase 4: Implement compact Block rows and expanded outliner cards

### Task 14: Replace duplicate compact Block controls

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Replace `block_summary` and the current `block_endpoint` control band with leading, main, and trailing regions.
2. Render exactly one leading checkbox for writable task Blocks and a non-interactive bullet for non-task Blocks.
3. Render Block content as styled text with at most two lines and ellipsis.
4. Render one metadata line using only task state and truthful child count.
5. Make the main region and disclosure chevron invoke the same expand or collapse behavior.
6. Ensure the checkbox target is isolated from the enclosing pressable and never expands, collapses, or navigates.
7. Remove the compact Open, More, and duplicate textual task actions and their obsolete test IDs.
8. Keep stable Block keys and the existing one-open preview state.
9. Run compact anatomy, task isolation, semantics, stable identity, and bounded rendering tests.

Expected GREEN result: Every compact Block has one predictable scan path and no competing duplicate actions.

### Task 15: Build the bounded expanded card

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Split compact and expanded visual endpoints while preserving one `Morphing_surface` and one stable logical list child.
2. Reuse the compact header anatomy and make the header or chevron collapse the card.
3. Render preview nodes in source order with depth indentation, quiet bullets, and connectors derived only from existing `preview_node.depth` data.
4. Keep the existing depth-two and eight-node Worker bound and show `More descendants…` only when `has_more` is true.
5. Add equal-height Add Child and Open footer actions separated by a quiet divider.
6. Add a handler that opens Detail with child editor state active for Add Child.
7. Keep Open as normal Detail and omit Add Child plus task mutation in recovery-only mode.
8. Use deterministic extents for regular and large-text profiles and update sparse overrides without changing index or key.
9. Use 220-millisecond `Ease_out_cubic` expansion and 190-to-220-millisecond accepted collapse behavior.
10. Run expanded card, preview bound, route isolation, motion, recovery, and feed restoration tests.

Expected GREEN result: One Block transforms in place into a bounded journal outliner card with isolated footer actions.

### Task 16: Style continuations, boundary, and saved notice

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Replace `More blocks…` with a low-emphasis non-button loading row and progress indicator only while its real request is pending.
2. Replace the Search boundary text with a rounded tonal card containing `Looking for something older?` and one functional `Search journal` action.
3. Replace the staged capture row with an `Entry saved` tonal banner, optional `Added to today` support, and Show action.
4. Keep durable Worker confirmation as the only transition that produces the success banner.
5. Preserve continuation fencing, stable keys, and near-tail admission behavior.
6. Run continuation, Search boundary, staged capture, semantics, and durability tests.

Expected GREEN result: Feed edge states feel intentional and expose no false affordances.

## Phase 5: Implement Capture and Search routes

### Task 17: Recompose Capture as a full-height editor

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Remove the Capture AppBar and repeated body title.
2. Render the shared compact toolbar with Cancel, `New entry`, and Save.
3. Render the accepted localized observed-day heading above the editor and use canonical day only as fallback.
4. Put the multiline editor in the remaining vertical fill region and retain revision IDs, focus events, newline submission, autofocus, and the 65,536-byte limit.
5. Use one inline status slot below the editor for every stage.
6. Render dirty discard confirmation inline with Keep Editing and destructive Discard.
7. Keep Save disabled for trimmed blank input and accepted pending saves.
8. Keep the page non-poppable while draft, confirmation, or save state is unresolved.
9. Run Capture composition, validation, durability, conflict, discard, accessibility, and route tests.

Expected GREEN result: Capture behaves like an immediate compose page without changing its durable mutation contract.

### Task 18: Recompose Search with a bounded results surface

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Add a clear-search handler that increments or fences request generation, clears matches and continuation, and returns to `Search_prompt` without closing the route.
2. Remove the Search AppBar, repeated title, and Close text action.
3. Render one top toolbar with Back, the revisioned field, and Clear.
4. Render prompt, searching, empty, partial, and failed states through shared tonal status components.
5. Render stable Block result rows grouped by localized day context with snippet, ellipsis, and disclosure.
6. Keep page-only results visibly non-interactive until day navigation exists.
7. Put result content in a bounded vertical fill scroll view or sparse list that remains usable at 50 results.
8. Expose Continue Search only in partial state and Retry only if it uses an existing real retry transition.
9. Preserve debounce, normalization, request bounds, automatic candidate continuation, cap, and stale-response fencing.
10. Run all Search behavior, scrolling, semantics, Back, and Detail navigation tests.

Expected GREEN result: Search uses a single clear hierarchy and bounded result viewport without weakening query behavior.

## Phase 6: Implement Detail, Edit, and Add Child composition

### Task 19: Recompose loading and ready Detail pages

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Remove both Detail AppBars and render the shared compact toolbar with Back, Block context, and writable Edit.
2. Keep the same tonal page background during loading and ready states.
3. Render loading as a compact progress or skeleton-like tonal Block surface.
4. Render full root content, task state, truthful child metadata, and writable task checkbox in a primary Block surface.
5. Render immediate children as an outliner or separated rows under a level-two Children heading.
6. Omit child count when the projection cannot prove a total.
7. Omit `More children…` unless a real continuation handler is added within existing application APIs.
8. Render Add Child as the one contextual primary action and keep Edit only in the toolbar.
9. Preserve stable page keys, Slide transition, retained feed state, and platform Back behavior.
10. Run Detail composition, task mutation, child bounds, route identity, recovery, and Back tests.

Expected GREEN result: Detail separates content, hierarchy, and actions without inventing continuation behavior.

### Task 20: Share editor and conflict presentation

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Reuse the Capture editor and status composition for Detail Edit and Add Child while retaining their independent state and request handlers.
2. Replace the primary surface with the Edit editor and insert the Add Child editor as a nested surface beneath the root Block.
3. Use the shared toolbar or inline controls for Save and Cancel according to the target hierarchy without duplicating actions.
4. Render `This Block changed`, latest saved content, retained user draft, and only actions supported by the existing conflict policy.
5. Ensure conflict semantics announce the state without reading both full content values through the live region.
6. Preserve explicit dirty discard resolution and non-poppable editor routes.
7. Preserve durable save confirmation, queue rejection, Worker failure, and draft retention behavior.
8. Run editor, conflict, durability, discard, semantics, and recovery tests.

Expected GREEN result: All editors share one visual and interaction language while preserving their existing domain transitions.

## Phase 7: Complete lifecycle, accessibility, and responsive behavior

### Task 21: Recompose lifecycle states inside the shell

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Keep Opening and Loading inside the header shell with centered compact progress and one live-region label.
2. Render read-write Empty with friendly guidance and one New entry action.
3. Render recovery-only Empty with explanation and no mutation action.
4. Render Recovery only as a persistent warning banner while keeping read paths available.
5. Render Mutation locked as a high-emphasis warning surface with only actions that are implemented and safe.
6. Render terminal restart-required state without a false Retry action.
7. Keep drafts visible in route-local queue-busy and Worker-unavailable failures.
8. Run all lifecycle, recovery, terminal, durability, and live-region tests.

Expected GREEN result: State changes no longer jump to unrelated plain layouts or expose dead actions.

### Task 22: Finish semantics, target sizing, and responsive profiles

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.

Steps:

1. Audit every control named by the design document for explicit label, role, enabled state, selected or expanded value, and at least 48-by-48 target size.
2. Ensure the compact Block is announced once with concise task, child, durability, and expansion values.
3. Exclude all decorative bullets, connectors, dividers, and progress backgrounds from semantics.
4. Apply level-one route-title and level-two day-heading semantics where supported.
5. Set regular and large-text deterministic extents to the tested 88 and 104 pixel values.
6. Ensure bold text changes weight without making every Block appear selected.
7. Verify reduced motion changes interpolation only and leaves semantics, focus order, and controls identical.
8. Verify compact, regular, and wide inset profiles and the 720-pixel maximum width.
9. Run the complete accessibility and responsive test groups.

Expected GREEN result: Density, responsiveness, and environment changes preserve reachable and non-duplicated controls.

## Phase 8: Refactor and verify

### Task 23: Refactor only after GREEN

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml` only to remove test duplication without changing expectations.

Steps:

1. Use `@code-simplify` to review newly added presentation helpers and event dependency tuples.
2. Remove obsolete render helpers, test IDs, labels, and code paths rather than retaining compatibility wrappers.
3. Consolidate repeated editor, toolbar, status, action, and decoration code.
4. Keep state transitions and Worker request functions separate from view-only helpers.
5. Confirm no app-specific Flutter widget or renderer primitive was introduced.
6. Run `ocamlformat --check app/application.ml test/feed_app_test.ml` if the repository toolchain exposes the configured formatter.
7. Run `dune exec test/feed_app_test.exe`.
8. Run `dune test`.

Expected result: All tests remain green and the obsolete widget hierarchy is absent from source and rendered output.

### Task 24: Audit forbidden and obsolete paths

Files:

- Inspect the entire `/Users/rcmerci/gh-repos/logseq_journal` worktree.

Steps:

1. Run `git status --short` and distinguish pre-existing user changes from redesign changes.
2. Run `git diff -- app/application.ml app/application.mli test/feed_app_test.ml` and review every redesign hunk.
3. Run `git diff --name-only -- spec app/dune test/dune dune-project flutter` and prove the redesign did not modify forbidden files.
4. Run `rg -n 'block-more:|Mark done|Mark to do|app_bar.*Today|app_bar.*Search|app_bar.*Capture|More children' app/application.ml test/feed_app_test.ml`.
5. Confirm every remaining match is either an intentional domain string or remove the obsolete presentation path.
6. Run `dune test` one final time.

Expected result: The diff contains only authorized application and test changes and no compatibility layer retains the old UI.

### Task 25: Perform device and visual QA

Files:

- Do not change source unless a reviewed QA defect requires a new RED test first.

Steps:

1. Launch the existing Flutter host using the repository's documented development command from `/Users/rcmerci/gh-repos/logseq_journal/flutter`.
2. Capture Feed, expanded card, drawer, Capture, Search results, and Detail at 390 by 844 logical pixels in light mode.
3. Capture Feed, expanded card, editor, warning, and error states in dark mode.
4. Review compact text scale 1.3 or greater, reduced motion, high contrast, recovery only, save rejection, edit conflict, mutation locked, and restart-required states.
5. Review a window with at least 720 pixels of content width for centered Feed, drawer, Search, and Detail.
6. Check hierarchy, clipping, ellipsis, touch reachability, safe-area clearance, final-row reachability, connector alignment, focus order, and contrast.
7. Answer the quick Capture, 88 and 104 pixel extent, smallest-device footer, dark contrast, press feedback, and Detail count or continuation validation questions with observed evidence.
8. For any failed criterion, add a failing automated test where feasible, confirm RED, implement the smallest correction, and rerun automated plus affected visual QA.

Expected result: Every required visual matrix state has reviewed evidence and no unresolved blocker remains.

## Edge cases

| Edge case | Required behavior |
| --- | --- |
| Blank or whitespace-only Capture draft | Save remains disabled and no Worker mutation is sent. |
| 65,536-byte editor boundary | The maximum accepted content remains usable and over-limit input reports one live error. |
| Task checkbox nested near row pressable | One activation changes task only and never triggers expansion or navigation. |
| Preview request is still loading | The same Block remains expanded with deterministic extent and compact progress feedback. |
| A second Block expands during animation | Old collapse and new expansion share stable keys and start from renderer-interpolated state. |
| Expanded Block leaves projection | Preview state is sanitized and no extent override points at another slot. |
| Capture saved while feed is away from top | Success is staged and Show returns to the admitted entry without falsely replacing retained rows. |
| Recovery-only mode | Read, Search, preview, and Detail work while every mutation target is absent. |
| Drawer is open over a pushed route | Local drawer close is consumed before the route pop transition. |
| Search query is cleared during debounce or request | Old scheduled or returned work cannot repopulate results. |
| Fifty Search results | Results remain bounded and independently scrollable. |
| Page-only Search match | It cannot announce or look like an enabled button. |
| Dirty editor receives platform Back | Route remains and explicit discard resolution is required. |
| Conflict response | Draft remains, latest saved content is shown once, and durability is not falsely announced. |
| Restart-required terminal state | No Retry or mutation action is rendered. |
| Text scale or bold text changes | Deterministic extent changes preserve reachable targets and ellipsis. |
| Reduced motion toggles during expansion | Geometry resolves to the committed endpoint and no outgoing tree remains interactive. |
| Safe-area bottom inset changes | New entry never covers the final reachable feed row. |
| Wide window | Reading column remains centered and capped at 720 pixels. |

## Checkpoints

Use `@executing-plans` and report after each implementation batch.

| Checkpoint | Completed phases | Required report |
| --- | --- | --- |
| 1 | Phase 1 | List every expected RED failure and confirm baseline non-redesign tests remain green. |
| 2 | Phases 2 and 3 | Show shell, drawer, tokens, and focused test output. |
| 3 | Phase 4 | Show compact and expanded Block behavior, stable extent evidence, and focused test output. |
| 4 | Phase 5 | Show Capture and Search route behavior and focused test output. |
| 5 | Phases 6 and 7 | Show Detail, lifecycle, accessibility, and responsive behavior with focused test output. |
| 6 | Phase 8 | Show full tests, forbidden-path audit, diff review, and visual QA evidence. |

## Testing Details

The primary test artifact is `/Users/rcmerci/gh-repos/logseq_journal/test/feed_app_test.ml` because it renders the real Bonsai component, drives real handlers, observes native widget props, and verifies durable behavior through the repository-backed Worker fixture.
Tests assert user-observable control isolation, navigation, persistence, bounded scrolling, accessibility semantics, environment response, and lifecycle state rather than private record shapes or type declarations.
The final regression gate is `dune test`, followed by device review through the unchanged Flutter host.

## Implementation Details

- Keep all application state, routes, handlers, semantics, and selected visual tokens in OCaml/Bonsai.
- Reuse `Navigation_shell`, `Sparse_extent_list`, and `Morphing_surface` without moving per-frame renderer state across FFI.
- Preserve stable Block, day, route, page, and sparse-slot keys.
- Remove obsolete UI controls and test expectations instead of adding compatibility paths.
- Keep feed previews bounded to depth two and eight nodes.
- Keep Search bounded to the existing day, slot, candidate, query, and result limits.
- Keep durable Worker confirmation as the source of saved state.
- Omit controls whose backing transition is not implemented.
- Derive responsive spacing and motion from `Environment.snapshot`.
- Do not modify `spec/`, Dune, or Flutter host files.

## Question

Source implementation remains blocked until the user explicitly overrides the `003-journal-ui-ux-redesign.md` document status that says implementation is intentionally deferred and does not authorize source or test changes.
Once authorization is provided, the first implementation decision is to include the functional quick Capture header action for device review, while retaining the extended New entry action as the primary control.
The first device QA pass must decide whether to keep that shortcut and must validate 88 and 104 pixel row extents, expanded footer reachability, dark-token contrast, press feedback, and truthful Detail count or continuation presentation.

---
