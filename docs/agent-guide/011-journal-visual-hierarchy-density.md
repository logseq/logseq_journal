# Journal Visual Hierarchy and Density Implementation Plan

Goal: Refine the Journal timeline into a lighter, denser paper-like reading surface without regressing accessibility, bounded virtualization, swipe deletion, Capture, or adaptive text behavior.

Architecture: Keep the OCaml application as the sole owner of visual tokens, semantics, layout, routes, and interaction state.
Apply the immediately available hierarchy changes through project-local tokens and widget composition, while recording scroll-responsive Header compaction and explicit tabular figures as framework gates instead of approximating them in application code.

Tech Stack: OCaml 5.1.1, Bonsai v0.17, `bonsai_flutter` pinned at `a51276a09eb1cdf9c87f07ac4c7558ed7c6b2d69`, Flutter 3.44.8, Dart 3.12.2, Dune, `bonsai_flutter_test`, and Flutter golden tests.

Related: Builds on `docs/agent-guide/006-journal-reference-alignment.md`, `docs/agent-guide/007-journal-visual-diff-checklist.md`, `docs/agent-guide/008-journal-row-disclosure-interaction.md`, `docs/agent-guide/009-contextual-capture-bottom-sheet.md`, and `docs/agent-guide/010-journal-swipe-delete.md`.

## Problem statement

The product direction is correct and already close to a clean paper-and-journal surface.
The requested refinement is primarily about hierarchy, density, and affordance consistency rather than adding new features.

The feedback was based on rendered pixels, while the implementation uses logical pixels, device-pixel-ratio-aware dividers, safe areas, Dynamic Type scaling, and adaptive known row extents.
The raw pixel suggestions therefore cannot be copied directly into OCaml tokens without first normalizing them against the current `390 x 844` logical golden and the supported text-scale matrix.

The current working tree has also moved beyond several conditions visible in the reviewed screenshot.
Body text, timestamp styling, compact row extent, leading inset, Center Orb size, and semantic hit targets already satisfy or exceed much of the requested direction.
Changing those values again would make the interface smaller without delivering the intended hierarchy improvement.

The highest-value remaining changes are to shorten the static Header, remove the misleading decorative handle, give the Header title stack its own typography, remove the More icon's resting circle, move the timestamp column slightly inward, simplify the Center Orb shadow and plus geometry, and preserve the current dense compact rows.

## Testing Plan

I will update the OCaml token tests first so they require the new Header typography and geometry, standard trailing inset, Center Orb bottom inset, plus geometry, and shadow policy.

I will update the OCaml logical-view tests before implementation so they require the decorative Header handle and resting More surface to be absent, both side shells to retain equal `44 x 44` geometry, the title stack to remain independently centered, and the structural Header divider to remain one physical pixel.

I will update the row tests before implementation so they require the standard timestamp column to end `24` logical pixels from the trailing content edge in LTR and RTL, while preserving the existing source typography, timestamp typography, exact compact extent, adaptive stacked layout, row semantics, swipe wrapper, and task target.

I will update the application-view tests before implementation so they require a `48`-pixel Center Orb visual inside a `56`-pixel target, a thinner `18`-pixel plus, one restrained shadow layer, a `20`-pixel bottom inset above the safe area, and derived snackbar placement.

I will split the resting and swipe-threshold golden states before regenerating visual evidence.
The two current PNG files have identical SHA-256 value `754cd7c4e26048ac953ea7fd6a0edff93b4a3af85f810751ca38a2e68fad557b`, so the current resting golden is not independent evidence.

I will retain the complete behavior suites for Capture, direct-child disclosure, task mutation, recursive swipe deletion, Undo, durable commit, bounded sparse rendering, safe areas, Dynamic Type, RTL, high contrast, reduced motion, and route restoration.

Every implementation task must invoke `@Test-Driven Development (TDD)`, demonstrate the intended RED failure, add the minimum behavior, and rerun the focused and full GREEN suites.

NOTE: I will write *all* tests before I add any implementation behavior.

## Document status and scope

| Field | Value |
| --- | --- |
| Status | Implemented and verified through automated and compiled-runtime visual gates on 2026-08-12; physical-device assistive-technology review remains release QA. |
| Research date | 2026-08-12. |
| Repository root | `/Users/rcmerci/gh-repos/logseq_journal`. |
| Planning convention | `@Planning Documents` selected sequence `011`. |
| Visual baseline | `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/goldens/journal-reference-alignment.png` at `390 x 844`. |
| Historical reference | `/Users/rcmerci/gh-repos/logseq_journal/docs/agent-guide/assets/007-journal-visual-diff/approved-target-reference.png` at `941 x 1672`. |
| Primary scope | Static Header hierarchy, row trailing inset, Header shell consistency, Center Orb refinement, tests, and visual evidence. |
| Preserved scope | Capture sheet, row disclosure, task actions, swipe deletion, Undo snackbar, storage, routes, and sparse virtualization. |
| Framework-gated scope | Per-pixel scroll-responsive Header compaction and explicit OpenType tabular figures. |
| Prohibited changes | No `spec/` OCaml files, Dune files, `bonsai_flutter` files, or project-local Dart product widgets. |

The current working tree contains substantial uncommitted product work.
Implementation must preserve those changes and must not rewrite or revert unrelated files.

## Implementation evidence

The static visual-hierarchy tranche is implemented entirely in the OCaml application layer.
No `bonsai_flutter`, `spec/`, Dune, or project-local Dart product widget changes were required for this tranche.

The implementation adds dedicated Header subtitle and geometry tokens, removes the decorative Header handle and More resting surface, moves the timestamp column to a mirrored `24`-pixel trailing inset, and refines the Center Orb plus, shadow, and bottom inset.
The existing compact and adaptive row extents, Capture behavior, swipe deletion, Undo, sparse virtualization, semantics, and route ownership remain intact.

The test-first sequence demonstrated intended failures against the previous Header typography and anatomy, row trailing inset, Center Orb geometry, and real-runtime title geometry before the implementation changes were added.
The focused OCaml suites, complete Dune suite, generated-project and generated-host checks, Flutter analyzer, Flutter widget suite, and opt-in real-runtime golden test all pass after implementation.

The regenerated `390 x 844` resting golden has SHA-256 `a335e20848824b68c2c74507ec40d403b1bd062b05afadf5e6d5b6a808109866`.
The regenerated `390 x 844` swipe-threshold golden has SHA-256 `cef8184b1d5cceea0fbbf15bd9315f0aca2f064299190cd73a9fe8b0447237f4`.
The distinct hashes and rendered states restore independent visual evidence for the resting timeline and exposed destructive action.

Smooth scroll-responsive Header compaction and explicit OpenType tabular figures remain framework gates because the pinned public APIs expose neither a per-pixel sparse-list scroll contract nor text font features.
The application intentionally does not approximate either capability.

Physical iPhone safe-area review, VoiceOver order, and macOS pointer and keyboard review remain release QA items when the corresponding hardware and assistive-technology environment is available.

## Executive recommendation

Implement one focused static visual-hierarchy tranche now.
The tranche should reduce the normal Header's application-owned height from approximately `73` logical pixels to approximately `56` logical pixels before the top safe area, remove the decorative handle, and place the first Block approximately `17` logical pixels earlier.

Create a dedicated Header subtitle token instead of reusing the day-heading token.
Use `22/28 Bold` for the Header title, `15/20 Medium` for the Header subtitle, `15/20 Normal` for Block source, and `13/18 Normal` for timestamps.
This keeps the Header authoritative while preserving the already-correct lighter body hierarchy.

Keep the compact Block extent at `48` logical pixels.
This is already denser than the proposed `72–80` pixel rhythm once physical screenshot pixels and logical layout pixels are distinguished, and it leaves enough height for the `44`-pixel interaction target.

Keep the existing standard leading inset at `28` logical pixels and narrow leading inset at `24` logical pixels.
Move the standard trailing inset from `16` to `24` logical pixels so timestamps read as metadata inside the page rather than as edge chrome.

Keep the Center Orb visual at `48` logical pixels and its semantic target at `56` logical pixels.
Replace the two resting shadow layers with one lower-alpha layer, reduce the plus from `20 x 2` to `18 x 1.5`, and increase the bottom inset from `16` to `20` logical pixels.

Do not implement scroll-responsive Header compaction from sparse-list visible indexes.
That approximation would jump at item boundaries, couple product chrome to pagination events, and risk feedback loops when Header height changes the viewport.

## Research method and sources

The research inspected the current OCaml implementation, OCaml tests, Flutter compiled-runtime golden, current uncommitted changes, related planning documents, pinned public `bonsai_flutter` APIs, and official platform guidance.

Apple's current Human Interface Guidelines recommend clear hierarchy, removal of unnecessary elements, readable Regular through Bold weights, preservation of hierarchy under text scaling, stacked metadata at large text sizes, and at least `44 x 44` point hit regions for iOS controls.
The primary sources are [Design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles), [Typography](https://developer.apple.com/design/human-interface-guidelines/typography), [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), and [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).

Flutter exposes tabular numerals through [`FontFeature.tabularFigures`](https://api.flutter.dev/flutter/dart-ui/FontFeature/FontFeature.tabularFigures.html).
The pinned `bonsai_flutter` `Ui.Style.Text_style.create` surface exposes only font size, weight, line height, and color, so the application cannot request that feature through the current public protocol.

The pinned `Ui.Native_widget.Sparse_extent_list.vertical` surface emits typed visible-range changes but does not expose per-pixel scroll offset or delta.
The generic `Scroll_view` and `List_view` surfaces do expose scroll payloads, but replacing the sparse list with either would abandon the current bounded known-extent renderer and is not an acceptable visual-only change.

## Current implementation findings

### Header baseline

`/Users/rcmerci/gh-repos/logseq_journal/app/journal_header.ml` currently uses a `57`-pixel stack and `8` pixels of vertical padding on each side.
At normal text scale, the application-owned Header is therefore approximately `73` logical pixels high before its one-physical-pixel divider and the system top safe area.

The Header currently renders a `20/26 Semi_bold` title, a `14/20 Normal` subtitle, a `28 x 3` decorative handle, an `18`-pixel Menu icon, and an `18`-pixel More icon.
Both side shells are `44 x 44`, but the More icon alone has a `30`-pixel pale circular resting surface.

Menu and More remain deliberately noninteractive visual shells.
They have no action semantics, no target handlers, and no product routes, so this tranche must not add fake pressed feedback to them.

### Row baseline

`/Users/rcmerci/gh-repos/logseq_journal/app/journal_visual_tokens.ml` already uses `15/20 Normal` for Block source and `13/18 Normal` for timestamps.
`/Users/rcmerci/gh-repos/logseq_journal/test/journal_adaptive_test.ml` already verifies that normal timestamp contrast is at least `4.5:1`.

The standard compact row is already `48` logical pixels high for viewports at least `360` pixels wide and text scales through `1.3`.
The adaptive profile grows to `80`, `95`, `128`, or `186` logical pixels only when width or text scaling requires more room.

The leading inset is already `28` logical pixels on standard viewports and `24` logical pixels below `360` pixels.
The current standard trailing inset is `16` logical pixels, and the current timestamp slot is `52` logical pixels wide.

The compact row contains a one-physical-pixel divider and a body that remains at least `44` logical pixels high.
Shrinking the row below `48` would leave no practical allowance for the divider and minimum interaction target.

### Center Orb baseline

`/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` already renders a `48`-pixel dark visual inside a `56`-pixel target.
The resting shadow uses two concentric low-alpha layers in a `52`-pixel box, the plus uses `20 x 2` bars, and the bottom inset token is `16` logical pixels before safe-area handling.

The Center Orb is already bottom-centered in both LTR and RTL.
The final sparse-list clearance is already `56` pixels plus `24` pixels plus the safe-bottom inset.

### Golden baseline defect

`/Users/rcmerci/gh-repos/logseq_journal/flutter/test/goldens/journal-reference-alignment.png` and `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/goldens/journal-swipe-delete-threshold.png` are both `390 x 844` and currently have identical SHA-256 values.
The image visibly contains an exposed destructive swipe action.

The visual hierarchy tranche must restore one true resting golden and preserve one separate swipe-threshold golden.
No visual approval should use the duplicated current files as two independent states.

## Feedback disposition

| Feedback item | Current state | Decision | Rationale |
| --- | --- | --- | --- |
| Reduce Header height. | The static application Header is approximately `73` logical pixels before safe area. | Implement a `48`-pixel content stack with `4`-pixel vertical shell padding for approximately `56` logical pixels. | This produces the requested reduction without making text smaller. |
| Remove the small horizontal line. | A `28 x 3` decorative handle sits below the subtitle. | Remove it and its test IDs entirely. | It resembles an interactive page, drag, or tab indicator but has no action. |
| Reduce globally heavy typography. | Body is already `15/20 Normal`, and timestamp is already `13/18 Normal`. | Keep body and timestamp tokens, and strengthen only the Header title stack with dedicated tokens. | Further body reduction would not address the current code baseline. |
| De-emphasize time. | Time is already smaller, Normal weight, and uses a separate accessible color. | Preserve typography and color, and move the column inward to `24` pixels from the edge. | Lower opacity would risk violating small-text contrast. |
| Reduce Block vertical spacing. | Compact rows are already `48` logical pixels. | Preserve `48` compact extents and adaptive growth. | The current row is already denser than the requested visual rhythm and preserves the `44` target. |
| Reduce left and right whitespace. | Leading is already `24–28`, while trailing is `16`. | Preserve leading and increase standard trailing to `24`. | The source already has the requested leading position, while timestamps need more page inset. |
| Unify Menu and More. | Both use equal shells, but More has a resting circle. | Remove the More resting circle and retain equal transparent `44 x 44` shells. | The icons remain noninteractive until product actions exist. |
| Reduce the More circle. | The More visual circle is `30`, not `64`, in current code. | Remove it rather than resizing it. | A resting background makes one deferred shell look more actionable than the other. |
| Refine the bottom plus. | The visual is already `48`, and the target is `56`. | Keep those sizes, simplify the shadow, thin the plus, and use a `20` bottom inset. | This keeps the primary action clear while reducing design-system mismatch. |
| Compact Header on scroll. | Sparse list exposes visible ranges only. | Defer smooth compaction behind a public scroll-offset or pinned-header framework contract. | Item-index approximation would be discontinuous and unstable. |

## Target visual contract

### Normal compact viewport

```text
System safe-area top.
┌──────────────────────────────────────────┐
│ Menu             Today              More │
│               Fri, Aug 7                 │
├──────────────────────────────────────────┤
│ source content                    09:01  │
│ source content                    09:02  │
│ completed source                  10:00  │
│ older-day heading                        │
│ source content                    00:01  │
│                                          │
│                   +                      │
└──────────────────────────────────────────┘
System safe-area bottom.
```

The Menu and More shells remain visually symmetric and independently balanced around the centered title stack.
The centered stack must not shift when one side later gains more actions.

The decorative handle is absent.
The full-width one-physical-pixel Header divider remains because it separates fixed chrome from scrolling content and does not resemble a control.

### Typography tokens

| Role | Target token | Treatment |
| --- | --- | --- |
| Header title | `22/28 Bold`. | Primary page context. |
| Header subtitle | `15/20 Medium`. | Secondary date context with its own token. |
| Block source | `15/20 Normal`. | Preserve the current readable content weight. |
| Day heading and supporting text | `14/20 Normal`. | Preserve current group hierarchy. |
| Task status | Existing icon geometry and state color. | Preserve current non-text status treatment. |
| Timestamp | `13/18 Normal`. | Preserve current metadata hierarchy and contrast. |

The Header subtitle must no longer reuse `Tokens.typography.supporting`.
Day headings must not become heavier when the Header date changes.

### Header geometry

| Property | Current | Target |
| --- | ---: | ---: |
| Content stack height | `57`. | `48`. |
| Horizontal shell inset | `12`. | `12`. |
| Vertical shell inset per edge | `8`. | `4`. |
| Application Header before safe area | Approximately `73`. | Approximately `56`. |
| Side semantic shell | `44`. | `44`. |
| Icon visual slot | `30`. | `30`. |
| Icon glyph | `18`. | `18`. |
| Decorative handle | `28 x 3`. | Removed. |
| Structural divider | One physical pixel. | One physical pixel. |

### Row geometry

| Property | Narrow target | Standard target | Adaptive rule |
| --- | ---: | ---: | --- |
| Leading content inset | `24`. | `28`. | Preserve current width selection. |
| Trailing content inset | `24`. | `24`. | Mirror in RTL. |
| Compact Block extent | Not used below `360`. | `48`. | Preserve current selection. |
| Narrow normal-scale extent | `80`. | Not applicable. | Preserve stacked safety. |
| Time slot | `52`. | `52`. | Continue scaling in adaptive mode. |
| Minimum action target | `44`. | `44`. | Never reduce. |

The row must remain a continuous content flow rather than a collection of cards.
No row background, corner radius, elevation, or inter-row margin is added.

### Center Orb geometry

| Property | Current | Target |
| --- | ---: | ---: |
| Visual diameter | `48`. | `48`. |
| Target diameter | `56`. | `56`. |
| Plus bounds | `20 x 20`. | `18 x 18`. |
| Plus stroke | `2`. | `1.5`. |
| Resting shadow layers | `2`. | `1`. |
| Resting shadow outer box | `52`. | `52`. |
| Bottom inset | `16`. | `20`. |
| Final list clearance | `56 + 24 + safe bottom`. | Preserve. |

The pressed state remains immediate and visible.
Reduced motion removes release animation duration but does not remove the held-down visual state.

## Architecture and ownership

```text
Environment and product state in app/application.ml.
                     |
                     v
Visual roles and geometry in app/journal_visual_tokens.ml.
          |                    |                    |
          v                    v                    v
Header composition.       Row composition.      Center Orb overlay.
app/journal_header.ml.     app/journal_row.ml.   app/application.ml.
          |                    |                    |
          +--------------------+--------------------+
                               |
                               v
OCaml logical-view and semantic tests.
                               |
                               v
Compiled-runtime Flutter geometry assertions and separate goldens.
```

No product state crosses into Dart.
No new host adapter, platform channel, custom Flutter widget, or renderer extension is required for the immediately implementable tranche.

## Framework gates

### Scroll-responsive Header compaction

The desired expanded-to-compact transition requires one of the following public contracts.

1. `Sparse_extent_list.vertical` exposes per-pixel scroll offset and delta through a typed event.
2. A public pinned or collapsing Header primitive owns the animation and retained scroll controller on the Flutter side.

The first implementation should remain static until one of those contracts is available in the pinned dependency.
The project must not derive compact state from `visible_range.first_index`, because range changes are item-boundary and prefetch signals rather than continuous scroll progress.

The future behavior should use a `24–32` logical-pixel collapse distance, clamp progress from `0` to `1`, keep the date context semantic node stable, avoid per-frame full application reconciliation, and jump directly to the end state under reduced motion.

### Tabular timestamp figures

Explicit tabular figures require the `tnum` OpenType feature.
The current project API cannot serialize font features.

The application should continue using a fixed trailing slot and end alignment.
It must not substitute a monospaced custom font, manually space digits, or create a project-local Dart text widget as a compatibility path.

## File boundaries

| File | Planned treatment |
| --- | --- |
| `/Users/rcmerci/gh-repos/logseq_journal/app/journal_visual_tokens.mli` | Add dedicated Header subtitle and geometry contracts, add row trailing inset ownership, and expose refined Center Orb geometry without compatibility fields. |
| `/Users/rcmerci/gh-repos/logseq_journal/app/journal_visual_tokens.ml` | Implement the selected typography, Header, row, plus, shadow, and bottom-inset tokens. |
| `/Users/rcmerci/gh-repos/logseq_journal/app/journal_header.ml` | Remove the decorative handle and More resting surface, shorten the stack, and use the dedicated subtitle token. |
| `/Users/rcmerci/gh-repos/logseq_journal/app/journal_row.ml` | Replace the local trailing `16` literal with the selected token and mirror it in RTL. |
| `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` | Simplify the Center Orb resting shadow and plus geometry while preserving Capture and snackbar behavior. |
| `/Users/rcmerci/gh-repos/logseq_journal/test/journal_adaptive_test.ml` | Verify the complete visual token contract and preserved contrast and adaptive profiles. |
| `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml` | Verify Header anatomy, Header height, side-shell symmetry, Center Orb geometry, snackbar offset, and absence of removed visual paths. |
| `/Users/rcmerci/gh-repos/logseq_journal/test/journal_semantics_test.ml` | Verify LTR and RTL row insets, unchanged timestamp semantics, action separation, and exact extents. |
| `/Users/rcmerci/gh-repos/logseq_journal/test/journal_timeline_state_test.ml` | Preserve exact final clearance and sparse-list behavior. |
| `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/journal_runtime_golden_test.dart` | Separate resting and swipe-threshold capture states and assert final rendered geometry. |
| `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/goldens/journal-reference-alignment.png` | Regenerate only from a verified resting timeline. |
| `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/goldens/journal-swipe-delete-threshold.png` | Preserve a distinct image captured while the destructive action is exposed. |

No Dune file needs modification because all affected OCaml test executables already exist.
No `.mli` file under `spec/` needs clarification or modification.

## Requirement-to-evidence matrix

| Requirement | OCaml evidence | Flutter evidence | Manual evidence |
| --- | --- | --- | --- |
| Shorter Header. | Exact stack and padding nodes in `application_view_test.ml`. | First-row top and Header child centers. | `390 x 844` overlay review. |
| No decorative handle. | Negative test-ID and tree assertions. | No handle-colored decoration below the subtitle. | Resting golden review. |
| Clear typography hierarchy. | Exact token and text-style assertions. | Rendered font size and weight assertions. | iPhone and macOS review. |
| Quieter timestamp. | Exact token, palette, contrast, and slot assertions. | Rendered size, right inset, and source alignment. | Normal and high-contrast review. |
| Dense continuous rows. | Exact `48` compact extent and no card surface assertions. | Visible row count and final-row reachability. | Resting golden review. |
| Symmetric Header shells. | Equal shell size and absence of More surface. | Centered title and side icon positions. | LTR and RTL review. |
| Refined Center Orb. | Token and widget geometry assertions. | Visual, target, shadow, plus, safe-area, and pressed-state assertions. | iPhone safe-area review. |
| Swipe state remains independent. | Existing row wrapper and delete behavior suites. | Distinct resting and threshold golden hashes. | Compare both images. |
| Accessibility remains intact. | Semantics, target, contrast, adaptive, and RTL suites. | Flutter semantics and large-text geometry. | VoiceOver and keyboard review. |

## Implementation plan

### Phase 0: Protect the current baseline

#### Task 1: Record the exact pre-change state

1. Run `git status --short` from `/Users/rcmerci/gh-repos/logseq_journal`.
2. Record the files already modified before implementation.
3. Run `shasum -a 256` on both current golden PNGs.
4. Confirm that unrelated swipe-delete, Capture, storage, and Worker changes remain outside the visual tranche.
5. Do not stage, revert, or rewrite any pre-existing user change.

Expected result: The implementer has an explicit overlap list and confirms that both current golden files are identical before changing tests.

#### Task 2: Confirm the pinned framework gates

1. Inspect the resolved `Ui.Style.Text_style.create` signature.
2. Confirm that it has no font-feature field.
3. Inspect the resolved `Ui.Native_widget.Sparse_extent_list.vertical` signature.
4. Confirm that it has `on_visible_range` but no `on_scroll` callback.
5. Add no application approximation for either missing capability.

Expected result: Static Header refinement proceeds, while scroll compaction and explicit `tnum` remain deferred.

### Phase 1: Establish the complete RED suite

#### Task 3: Write the visual-token failures

1. Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_adaptive_test.ml`.
2. Require `22/28 Bold` Header title typography.
3. Require `15/20 Medium` Header subtitle typography.
4. Preserve the existing `15/20 Normal` entry and `13/18 Normal` timestamp assertions.
5. Require `48` Header content height, `4` vertical inset, `24` row trailing inset, `18` plus bounds, `1.5` plus stroke, one shadow layer, and `20` FAB bottom inset.
6. Preserve normal and high-contrast timestamp contrast assertions.
7. Run `opam exec -- dune exec test/journal_adaptive_test.exe`.

Expected result: The test fails only on the old token values or missing token fields.

#### Task 4: Write the Header anatomy failures

1. Modify `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.
2. Require the `journal-header-handle` test ID to be absent.
3. Require the `journal-more-surface` test ID to be absent.
4. Require the Menu and More shells to remain `44 x 44` with `30`-pixel visual slots and `18`-pixel glyphs.
5. Require the Header stack to be `48` pixels high and the vertical padding to be `4` pixels on each edge.
6. Preserve the independent center, top-only Header SafeArea, one-physical-pixel structural divider, and noninteractive Menu and More boundary.
7. Run `opam exec -- dune exec test/application_view_test.exe`.

Expected result: The test fails because the old handle, More surface, stack height, and padding remain.

#### Task 5: Write the row-geometry failures

1. Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_semantics_test.ml`.
2. Require `24` logical pixels of trailing body padding for standard LTR rows.
3. Require the same inset on the mirrored side for standard RTL rows.
4. Preserve `28` standard leading and `24` narrow leading behavior.
5. Preserve exact `48` compact extent, adaptive stacked metadata, `52` time slot, one-line ellipsis, and semantic timestamp text.
6. Preserve nonoverlapping task, parent-row, swipe, and leaf semantics.
7. Run `opam exec -- dune exec test/journal_semantics_test.exe`.

Expected result: The test fails only because the old trailing inset is `16`.

#### Task 6: Write the Center Orb and snackbar failures

1. Modify `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.
2. Preserve the `48` visual and `56` target assertions.
3. Require `18 x 1.5` plus bars.
4. Require one restrained `52`-pixel resting shadow layer and reject the removed second layer.
5. Require a `20`-pixel bottom inset above the consumed safe area.
6. Require the delete snackbar to remain above the safe bottom, Center Orb target, new bottom inset, and existing vertical gap.
7. Preserve immediate pressed feedback, reduced-motion behavior, Capture route admission, and no initial or final row occlusion.
8. Run `opam exec -- dune exec test/application_view_test.exe`.

Expected result: The test fails on old plus, shadow, or bottom-inset geometry without failing Capture behavior.

#### Task 7: Write independent golden-state failures

1. Modify `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/journal_runtime_golden_test.dart`.
2. Capture the resting `journal-reference-alignment.png` before beginning the swipe gesture.
3. Capture `journal-swipe-delete-threshold.png` only while the end action is exposed.
4. Require the two states to have distinct visible conditions in the test.
5. Add Header bottom, first-source top, time right edge, Center Orb center, Center Orb bottom-safe gap, and resting absence of the destructive surface assertions.
6. Run the real-runtime golden test without update mode.

Expected result: The test fails against the duplicated old visual evidence or old geometry.

#### Task 8: Validate the RED phase

1. Run the three focused OCaml executables.
2. Confirm every failure names an intended visual contract.
3. Confirm existing Capture, disclosure, task, delete, Undo, and persistence tests do not fail for unrelated reasons.
4. Remove any assertion that merely checks a record layout without visible or semantic behavior.
5. Do not update goldens during the RED phase.

Expected result: The failing suite is specific, minimal, and cannot pass on the old implementation.

### Phase 2: Implement the visual hierarchy

#### Task 9: Implement visual tokens

1. Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_visual_tokens.mli`.
2. Add the Header subtitle token and explicit Header geometry record.
3. Add the trailing row inset and refined Center Orb geometry to the authoritative records.
4. Remove obsolete handle-specific token fields instead of leaving compatibility fields.
5. Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_visual_tokens.ml`.
6. Implement the exact target values from this document.
7. Run `opam exec -- dune exec test/journal_adaptive_test.exe`.

Expected result: The token suite passes, while view tests remain RED.

#### Task 10: Recompose the Header

1. Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_header.ml`.
2. Remove the decorative handle node, spacer, color use, and test ID.
3. Remove the More resting decorated box and its test ID.
4. Use the dedicated Header subtitle token.
5. Apply the `48`-pixel content stack and `4`-pixel vertical shell padding.
6. Preserve the centered semantics node, side-shell geometry, one-line clipping, SafeArea ownership, structural divider, and environment boundary.
7. Run `opam exec -- dune exec test/application_view_test.exe`.

Expected result: Header assertions pass without introducing Menu or More actions.

#### Task 11: Move the timestamp column inward

1. Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_row.ml`.
2. Replace the local trailing spacing selection with the authoritative `24`-pixel token.
3. Apply it to the right in LTR and to the left in RTL.
4. Preserve the task target offset, source gap, time-slot width, divider, swipe content, and exact row extent.
5. Run `opam exec -- dune exec test/journal_semantics_test.exe`.

Expected result: LTR and RTL row suites pass with unchanged action counts and semantic labels.

#### Task 12: Refine the Center Orb

1. Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml`.
2. Parameterize the plus bars from tokens rather than local `20` and `2` literals.
3. Remove the obsolete second resting shadow layer and its test ID.
4. Preserve one low-alpha `52`-pixel shadow shell.
5. Apply the `20`-pixel bottom inset.
6. Preserve `48` visual, `56` target, centered placement, SafeArea ownership, pointer-down feedback, Capture action semantics, and delete-snackbar ordering.
7. Run `opam exec -- dune exec test/application_view_test.exe`.

Expected result: Center Orb and snackbar geometry tests pass without changing Capture state or routes.

### Phase 3: Restore trustworthy visual evidence

#### Task 13: Generate separate golden states

1. Build the current debug native artifact through the supported `bonsai-flutter exec` wrapper.
2. Run the real-runtime test with golden update mode from `/Users/rcmerci/gh-repos/logseq_journal/flutter`.
3. Confirm the resting image contains no visible destructive action.
4. Confirm the swipe-threshold image contains the end-to-start destructive action.
5. Confirm both files remain `390 x 844`.
6. Confirm their SHA-256 values differ.

Expected result: The resting and swipe-threshold files are distinct and each represents its named state.

#### Task 14: Review the visual hierarchy

1. Compare the new resting golden with the pre-change resting intent and the approved historical reference.
2. Verify that the Header bottom moved upward by approximately `17` logical pixels.
3. Verify that Today remains the strongest text and that Block source remains the reading focus below it.
4. Verify that timestamps are quieter and end `24` logical pixels from the content edge.
5. Verify that Menu and More have equal resting treatment.
6. Verify that the Center Orb remains obvious without becoming the screen's dominant element.
7. Reject the golden if any semantic target was visually shrunk to match its glyph.

Expected result: The page reads as one continuous journal surface with lighter chrome and no new decoration.

### Phase 4: Complete regression and device gates

#### Task 15: Run full automated gates

1. Run `opam exec -- dune runtest` from `/Users/rcmerci/gh-repos/logseq_journal`.
2. Run `opam exec -- bonsai-flutter sync-project --check` from `/Users/rcmerci/gh-repos/logseq_journal`.
3. Run `opam exec -- bonsai-flutter sync-host --check` from `/Users/rcmerci/gh-repos/logseq_journal`.
4. Run `opam exec -- bonsai-flutter exec --profile=debug -- flutter analyze --no-pub` from `/Users/rcmerci/gh-repos/logseq_journal/flutter`.
5. Run `opam exec -- bonsai-flutter exec --profile=debug -- flutter test --no-pub test` from `/Users/rcmerci/gh-repos/logseq_journal/flutter`.
6. Run the opt-in real-runtime golden without update mode.
7. Run `git diff --check` from `/Users/rcmerci/gh-repos/logseq_journal`.

Expected result: All commands exit `0`, the normal Flutter suite skips only explicitly opt-in cases, and the real-runtime golden passes when enabled.

#### Task 16: Run manual accessibility and platform review

1. Review iPhone portrait with top and bottom safe areas.
2. Review a narrow `320`-pixel viewport.
3. Review text scales `1.0`, `1.3`, `2.0`, and `3.2`.
4. Review LTR and RTL placement.
5. Review normal and high-contrast palettes.
6. Review reduced motion and held-down feedback.
7. Review VoiceOver order for date context, row task, parent row, Capture, snackbar, and Undo.
8. Review macOS pointer and keyboard focus without assuming iOS-only touch behavior.

Expected result: The hierarchy survives every supported environment without clipped Header text, overlapping timestamps, unreachable final rows, or false actions.

## Edge cases

| Edge case | Required outcome |
| --- | --- |
| Very long localized Header subtitle. | Clip to one line without moving the independently centered stack or overlapping side shells. |
| Text scale above `1.3`. | Preserve adaptive row growth and readable stacked metadata rather than forcing `48`-pixel rows. |
| `320`-pixel viewport. | Preserve the `24` leading and trailing insets, adaptive row, complete time, and independent task target. |
| RTL locale. | Mirror row content and time inset while keeping the Center Orb physically centered. |
| High contrast. | Preserve explicit timestamp and divider colors instead of applying lower opacity. |
| Reduced motion. | Use final static geometry and zero release duration while retaining pointer-down feedback. |
| Empty or loading timeline. | Use the same shortened Header and centered state message without a second top safe area. |
| Expanded parent and visible children. | Preserve exact sparse extents, depth padding, disclosure semantics, and swipe ownership. |
| Swipe deletion in progress. | Keep the entire row inside the swipe content and keep the resting golden free of destructive state. |
| Undo snackbar visible. | Position it above the safe bottom and Center Orb after the new bottom inset. |
| Capture sheet open. | Preserve route, barrier, focus, keyboard, and Timeline mounting behavior. |
| Long source near the time slot. | Ellipsize the source before the fixed slot and never overlap the timestamp. |
| Corrupt row without a timestamp. | Preserve an empty fixed time slot so row alignment remains stable. |
| Wide macOS viewport. | Preserve the `720`-pixel maximum content width and center the complete Header, timeline, snackbar, and Center Orb composition. |

## Questions and areas requiring clarity

The static tranche has no blocking product question.
The recommended values are normalized logical pixels, not direct copies of physical screenshot measurements.

The following later decisions remain explicit rather than silently assumed.

1. Menu and More need real product actions before they can receive truthful pressed feedback or accessibility action semantics.
2. Smooth scroll compaction needs a public sparse-list scroll contract or pinned Header primitive before implementation in this repository.
3. Explicit tabular figures need a public font-feature field in the pinned text-style protocol.
4. The structural full-width Header divider is retained, while only the misleading short decorative handle is removed.
5. If visual review rejects `22/28 Bold` and `15/20 Medium`, update only the dedicated Header tokens and their evidence rather than changing shared supporting or body roles.

## Verification commands

Run focused OCaml tests during RED and GREEN development.

```sh
cd /Users/rcmerci/gh-repos/logseq_journal
opam exec -- dune exec test/journal_adaptive_test.exe
opam exec -- dune exec test/application_view_test.exe
opam exec -- dune exec test/journal_semantics_test.exe
```

Run the complete OCaml and generated-host checks after focused tests pass.

```sh
cd /Users/rcmerci/gh-repos/logseq_journal
opam exec -- dune runtest
opam exec -- bonsai-flutter sync-project --check
opam exec -- bonsai-flutter sync-host --check
git diff --check
```

Run Flutter through the native-artifact profile wrapper.

```sh
cd /Users/rcmerci/gh-repos/logseq_journal/flutter
opam exec -- bonsai-flutter exec --profile=debug -- flutter analyze --no-pub
opam exec -- bonsai-flutter exec --profile=debug -- flutter test --no-pub test
```

Run the real-runtime golden without update mode for acceptance.

```sh
cd /Users/rcmerci/gh-repos/logseq_journal/flutter
RUN_REAL_OCAML_GOLDEN=1 opam exec -- bonsai-flutter exec --profile=debug -- \
  flutter test --no-pub test/journal_runtime_golden_test.dart
```

Use `--update-goldens` only in Task 13 after every logical geometry assertion is GREEN.

## Testing Details

The token tests verify behaviorally meaningful visual roles by tracing them into Header, row, timestamp, and Center Orb composition rather than testing isolated record shape alone.
The logical-view tests verify rendered anatomy, semantics, SafeArea ownership, exact known extents, mirrored layout, and absence of obsolete decorative paths.
The compiled-runtime test verifies actual Flutter geometry, press and swipe states, final-row reachability, and two independent raster states from the real OCaml runtime.

## Implementation Details

- Keep all visual decisions in `Journal_visual_tokens` and remove obsolete handle fields instead of preserving aliases.
- Give the Header subtitle its own token so day headings do not inherit Header emphasis.
- Preserve `48` compact rows and every adaptive extent.
- Preserve `44` minimum action targets, `56` Capture target, and accessible timestamp contrast.
- Remove the More resting surface without inventing Menu or More actions.
- Move the time column inward through one mirrored trailing-inset token.
- Keep one structural Header divider and remove only the misleading short handle.
- Simplify the Center Orb shadow and plus without changing Capture state, route, or semantics.
- Keep smooth Header compaction and explicit `tnum` behind pinned public API gates.
- Regenerate resting and swipe goldens as distinct states only after all geometry tests pass.

## Question

Should a future framework upgrade add per-pixel sparse-list scroll events or a Flutter-owned pinned Header primitive first.
The recommendation is a Flutter-owned pinned Header primitive because it can animate at frame rate without reconciling the complete OCaml application tree on every scroll tick.

---
