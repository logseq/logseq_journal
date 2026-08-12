# Journal Timeline UI Implementation Plan

Goal: Build the screenshot-directed Journal timeline with all product UI and application logic implemented in OCaml, using only capabilities already supported by the pinned `bonsai_flutter` dependency.

Architecture: OCaml and Bonsai own the logical widget tree, routes, reducers, effects, domain model, timeline projection, persistence policy, visual tokens, and accessibility intent.
An OCaml Serial Worker exclusively owns the app-private DataScript database backed by SQLite, while the generated Flutter host only executes existing renderer and operating-system mechanics.
No new `bonsai_flutter` capability, app-specific Flutter product widget, or Dart product layer is part of this release.

Tech Stack: OCaml 5.1.1, Bonsai v0.17, the currently pinned `bonsai_flutter`, `bonsai_flutter_test`, DataScript OCaml native SQLite, Flutter 3.44.8, Dart 3.12.2, and the existing Apple platform bridge.

Related: Supersedes `002-journal-rewrite.md`, `003-journal-ui-ux-redesign.md`, and `004-journal-ui-ux-redesign-implementation.md` where their product behavior or ownership decisions differ from this document.

## Problem statement

The supplied `941 x 1672` PNG is the product authority for the root Journal experience.

It shows a quiet edge-to-edge timeline with a centered Today context, a date subtitle, Menu, Search, More, reverse-chronological day sections, dense entries, a fixed time column, inline tag pills, task completion, child disclosure, an attachment thumbnail, and one lower-trailing capture action.

The source is a concept artboard rather than a device-native specification, so its hierarchy and visual rhythm are authoritative while raster noise and source pixels are not direct Flutter logical pixels.

The current repository contains three relevant snapshots.

| Snapshot | Relevant state | Planning treatment |
| --- | --- | --- |
| `HEAD` | A small OCaml in-memory application | Historical baseline only |
| Git index | A substantial OCaml/Bonsai application with a Serial Worker, DataScript, SQLite, recovery, and platform calendar work | Reusable architectural baseline |
| Current worktree | OCaml files and the managed manifest are being removed while a pure-Flutter product tree is present under `flutter/lib/app`, `flutter/lib/core`, and `flutter/lib/features` | Superseded by this plan and removed only after an exact diff review |

The previous version of this PRD selected a pure Flutter and Dart application and proposed implementing five missing renderer capabilities.

Both decisions are replaced by the following mandatory rules.

All Journal UI and logic must be implemented in OCaml unless an operating-system action necessarily executes through an already supported host boundary.

Missing `bonsai_flutter` capabilities must not be implemented, patched, copied into the app, or approximated with an app-specific Dart widget.

Product slices that genuinely depend on those capabilities are deferred until a supported `bonsai_flutter` release exposes them through its public typed API.

No compatibility layer is required for the previous Dart plan, the current Mail-inspired UI, Search, the old database, or obsolete OCaml APIs.

## Confirmed product decisions

| Decision | Confirmed scope |
| --- | --- |
| Product ownership | OCaml owns all Journal UI declaration, state, behavior, domain logic, persistence logic, visual policy, and accessibility intent. |
| Flutter boundary | Project Flutter contains only generated-host code, the existing mechanical platform adapter, and real-runtime verification harnesses. |
| Framework policy | The first release uses the pinned public `bonsai_flutter` API without upstream changes, local renderer extensions, or private patches. |
| Canonical data | An app-owned DataScript database backed by SQLite is the only canonical store. |
| Real Logseq graph | The application does not read, write, synchronize, import, or migrate one. |
| Entry time | The right column shows the original creation wall time from the original creation time-zone snapshot. |
| Search | Search is not supported in the first release, and the Search control shown in the concept artboard is not rendered. |
| Tags and mentions | Their source remains visible as plain text, while styled inline pills and token interaction are deferred. |
| Timeline rows | Rows use known OCaml-selected height profiles and one-line ellipsis rather than intrinsic measured height. |
| Child disclosure | Direct-child expansion remains OCaml-owned and uses the existing Button, Tap, label, value, and hint semantics without claiming a formal expanded trait. |
| Attachments | Attachment selection, persistence, thumbnails, and preview are deferred as one complete product slice. |
| Dune files | Explicit authorization to modify or remove the project Dune files was granted on 2026-08-09. |
| Old database | Legacy database paths outside the exact canonical store path are never scanned, opened, read, migrated, written, deleted, or cleaned up. |
| Menu and More | Both controls remain visible, but their exact first-release items are the one unresolved product decision. |

## Testing Plan

I will add OCaml behavior tests for creation-time preservation, journal-day assignment, ordering, task transitions, direct-child projection, pagination, revision fencing, request generations, route state, and failure recovery.

These tests will call public OCaml domain, repository, Worker, and Bonsai application boundaries instead of asserting record layout or mocking the behavior under test.

I will add OCaml logical UI tests that render the Bonsai tree, activate its real handlers, and verify visible hierarchy, fixed profile selection, actions, routes, textual semantics, and state transitions.

I will verify the currently pinned renderer through its existing `Sparse_extent_list`, text input, Pressable, semantics, navigation, and host tests without adding upstream tests or implementation.

I will keep the existing generic text-input tests for UTF-16 selection, Chinese and Japanese composition, emoji, combining characters, correction fencing, focus retention, and disposal.

I will add project Flutter tests only for the mechanical platform adapter, generated-host construction, and a compiled real-OCaml-runtime integration harness.

Project Flutter tests must not create a fake Dart repository, reproduce Journal reducers, build an alternative Dart Journal screen, or register an app-specific native widget.

I will add real-runtime golden tests for the normalized screenshot geometry, accepted Search omission, plain inline source, accepted thumbnail omission, fixed row profiles, dark mode, and safe-area variants.

I will test direct-child disclosure with the existing semantics API and require VoiceOver to announce one focus target with an accurate Show or Hide label, Collapsed or Expanded textual value, and Tap action.

If that disclosure control produces duplicate focus targets or an untruthful announcement, the first release will omit the disclosure control instead of changing Flutter or `bonsai_flutter`.

I will profile a compiled OCaml runtime with a `10,000`-record durable release corpus and run a separate `50,000`-row synthetic stress case without treating the framework prototype as a production service-level promise.

The release gate limits the OCaml rolling timeline cache to `512` logical slots and the supplied renderer window, including overscan, to `40` rows.

Each implementation tranche follows RED, verified RED, minimal GREEN, verified GREEN, refactor, and a second complete GREEN run.

NOTE: I will write *all* tests before I add any implementation behavior.

## Executive decision

Keep the OCaml/Bonsai runtime as the only application runtime.

Keep an OCaml Serial Worker as the only DataScript and SQLite owner.

Replace the current product UI and obsolete application behavior with a screenshot-directed OCaml UI rather than replacing OCaml with a Dart application.

Restore the generated managed Flutter host as the host authority.

Remove Dart product-layer directories, Dart Journal domain types, Dart controllers, Dart repositories, Dart SQLite dependencies, and Dart-built Journal pages introduced by the superseded plan.

Use only existing `bonsai_flutter` widgets and host effects in this release.

Do not modify `/Users/rcmerci/gh-repos/bonsai_flutter`, do not edit the generated `.bonsai-flutter` mirror directly, and do not create a private capability fork.

When a later supported dependency exposes a deferred capability, evaluate that released API in a new planning document before expanding product scope.

## Ownership contract

| Owner | Must own | Must not own |
| --- | --- | --- |
| OCaml Bonsai graph | Routes, reducers, effects, Menu and More state, date state, Capture, Detail, visual tokens, textual semantics, actions, logical widget tree, expanded child IDs, and mounted logical window | SQLite handle, Flutter controller, font measurement, image decoder, or pointer deltas |
| OCaml domain and projection | Journal model, creation time, ordering, known row profiles, stable slots, paging decisions, and source-to-view projection | Flutter widgets, Dart models, or renderer extensions |
| OCaml Serial Worker | DataScript schema, app-private SQLite, transactions, pagination, revisions, mutation IDs, and recovery | Widget tree, route state, or Flutter resources |
| Existing Flutter renderer | Accepted-frame realization, layout, paint, known-extent scrolling, focus, IME echo, animation, and native semantics mapping | Journal types, routes, product state, colors, spacing policy, parser, SQL, paging, or conflict policy |
| Existing platform bridge | Application Support root, locale, time zone, calendar facts, and lifecycle events | Database path choice, schema version, Journal mutations, or UI decisions |

Flutter executing layout does not authorize Flutter to select product hierarchy, tokens, copy, actions, or state.

The project does not add Flutter code merely because an OCaml composition is less convenient.

## Deferred `bonsai_flutter` capabilities

The following capabilities are not first-release implementation tasks.

| Missing public capability | Dependent product behavior that is deferred | First-release behavior using current APIs | Future activation gate |
| --- | --- | --- | --- |
| Structured inline flow with independently styled text and embedded OCaml children | Styled hashtag and mention pills in arbitrary source order | Render the complete source as one plain `Widget.text` value with one-line ellipsis | A supported pinned dependency exposes a typed public API and passes a separate integration spike |
| Intrinsic measured virtual list | Arbitrary multiline timeline rows and renderer-measured height changes | Use `Sparse_extent_list` with exact OCaml-selected profile extents | A supported pinned dependency exposes measured variable-height virtualization with bounded mounts and anchor proof |
| Bounded local-file image rendering | Attachment thumbnails and full-screen local preview | Render no attachment affordance or placeholder | A supported pinned dependency exposes a safe local image source with decode bounds and failure behavior |
| Formal expanded or collapsed semantics | Native disclosure trait and distinct Expand or Collapse actions | Use one existing Button with Tap plus stateful Show or Hide label, textual value, and hint | A supported pinned dependency exposes a formal typed expanded state and actions |
| Working generic single-file picker effect | Attachment selection and admission | Capture and Detail contain no attachment action | A supported pinned dependency exposes a working supported single-file response contract |

No disabled control, inert thumbnail, fake pill, placeholder attachment route, or unreachable persistence schema is retained for a deferred feature.

The concept artboard continues to document the eventual visual target, but first-release goldens explicitly accept these omissions.

## Existing capability selection

The existing OCaml API already provides styled plain text, ellipsis, Flex layout, padding, constraints, rounded decoration, safe areas, Stack overlays, pressable controls, dialogs, Navigator pages, text input, environment snapshots, and logical semantics.

The existing native registry already provides `Sparse_extent_list`, a navigation shell, and swipe mechanics.

The existing text-input protocol already provides session identity, document revision, accepted local revision, correction modes, UTF-16 selection, composing ranges, retained focus, and controller disposal.

The existing environment snapshot provides viewport width, viewport height, device pixel ratio, text scale, brightness, locale, safe-area insets, and accessibility flags to OCaml.

Header, Today, Menu, More, day headings, fixed-profile rows, time columns, task controls, child disclosure, the FAB, Capture, Detail, and date selection are therefore expressible without a Dart Journal widget.

The first-release editor remains plain source text while focused.

Live syntax coloring, editable inline chips, attachments, and intrinsic timeline rows are deferred.

## Decision drivers

| Driver | Required first-release outcome |
| --- | --- |
| Ownership mandate | All product UI and logic are OCaml-owned. |
| Framework constraint | No new `bonsai_flutter` capability or app-specific Flutter product widget is added. |
| Screenshot direction | Preserve the overall hierarchy, centered date context, dense timeline, time column, task state, disclosure, and FAB while documenting accepted omissions. |
| Large data | Support a `10,000`-record durable release corpus, retain a `50,000`-row stress case, and keep OCaml and Flutter windows explicitly bounded. |
| Editing | Use the existing generic IME mechanics without a Dart Journal editor or parser. |
| Accessibility | Use OCaml-authored semantics supported by the current renderer, large hit regions, adaptive known-height profiles, and truthful disclosure text. |
| Local-first durability | Use Worker-owned app-private SQLite with deterministic recovery. |
| Platform coverage | Deliver iOS and macOS without placing product behavior in Swift or Dart. |
| Generator authority | Make `sync-project --check` and `sync-host --check` clean after restoring the managed manifest and host. |
| Clean-slate policy | Remove obsolete UI, Search, Dart application paths, attachment dead paths, and legacy database behavior instead of adapting them. |

## Alternatives considered

| Option | OCaml ownership | Current dependency only | Screenshot completeness | Complexity | Decision |
| --- | --- | --- | --- | --- | --- |
| OCaml application with reduced first-release scope and existing renderer | Exact | Exact | Deliberately incomplete | Lowest compatible option | Selected |
| Add the five capabilities to `bonsai_flutter` now | Exact after framework work | Violates instruction | High | High cross-repository risk | Rejected |
| Add app-specific Dart widget fallbacks | Violates mandate | Avoids upstream work | Potentially high | Creates a second product runtime | Rejected |
| Pure Flutter and Dart application | Violates mandate | Exact | High | Duplicates product ownership in Dart | Rejected |
| SwiftUI application | Violates chosen stack | Not applicable | High on recent Apple systems | Apple-only and separate editor paths | Rejected |

The selected option is intentionally a text-first, single-line, known-extent milestone.

It must not be described as pixel-complete relative to the concept artboard.

## Research and observed evidence

### Screenshot forensics

The PNG is `941 x 1672`, RGB and sRGB, with a ratio near `9:16`.

It includes iOS status and home chrome but should be treated as a concept artboard rather than evidence for a specific device model.

A useful measurement hypothesis is approximately two source pixels per Flutter logical pixel, but implementation geometry must be normalized into clean tokens and verified on real viewports.

| Element | Observed source geometry | First-release normalized decision |
| --- | --- | --- |
| Header and body divider | Approximately `y = 239-240` | Use safe-area top plus a fixed profile-aware header body and one physical-pixel divider. |
| Menu leading edge | Approximately `x = 54` | Use a `44 x 44` hit target around the existing text or shape glyph. |
| Center title | Today and subtitle are visually centered | Center the title group independently from side action count. |
| Search | A visible action surface appears on the right | Omit it because Search is outside first-release scope. |
| More | A visible action surface appears on the right | Keep it and require a confirmed action set. |
| Rows | Usually `94-97` source pixels | Use the compact `48` logical-pixel profile at normal scale. |
| Divider insets | Approximately `x = 37-897` | Use an `18` logical-pixel inset. |
| Content leading | Approximately `x = 58` | Use `28` logical pixels on standard width and `24` on narrow width. |
| Time column | Right edge near `87.4%` of width | Reserve a trailing time slot in compact mode and a separate second line at larger scales. |
| Tag pills | Small colored inline surfaces are visible | Render the same source as plain text until structured inline support exists. |
| Child disclosure | A chevron and count are visible | Use an OCaml-built disclosure button with existing textual semantics. |
| Thumbnail | Approximately `32 x 32` logical pixels under the scale hypothesis | Omit it until both picker and local-image support exist. |
| FAB | Approximately `48` logical pixels visually | Use a `56 x 56` minimum target with a `48` visual core. |

The source contains small RGB noise, inconsistent divider antialiasing, and slight row-height drift.

Implementation must use clean tokens rather than reproducing those artifacts.

### Visible facts and implementation decisions

| Screenshot fact | First-release decision |
| --- | --- |
| Days appear Today, Tue, then Mon | Sort day sections descending. |
| Entries within each day appear time-ascending | Sort top-level entries by explicit sibling order with stable ID as the tie-breaker. |
| Today is integrated into the header | Do not repeat a Today day label in timeline content. |
| Rows have no Logseq bullet | Do not render a default bullet. |
| Tags and mentions appear styled | Preserve their literal source but defer style and interaction. |
| A completed task retains dark text | Keep normal text color and add a green checked control without strike-through. |
| A child disclosure is visible | Expand or collapse direct children through OCaml state if the existing semantics construction passes device acceptance. |
| An image appears in one row | Treat the image and attachment affordance as an accepted first-release omission. |
| A dark FAB overlays the feed | Position it using safe-area insets and reserve bottom scroll padding. |

### Local capability audit

`Widget.text` supports an OCaml-supplied style, maximum line count, and ellipsis.

`Native_widget.Sparse_extent_list.vertical` accepts a total count, first index, default extent, sparse exact extent overrides, overscan, supplied OCaml children, and a visible-range event.

The existing sparse-list implementation and tests cover bounded mounts, sparse geometry, extent changes, and anchoring behavior.

The existing Pressable implementation contributes one Tap action while retaining descriptive child semantics.

The existing semantics API supports label, hint, value, role, checked state, focusability, heading level, sort key, and Tap action.

The existing semantics API does not expose a formal expanded state, distinct Expand or Collapse action, merge descendants, or exclude descendants.

The core rich-text API carries only a list of strings with one inherited style and therefore does not satisfy the visual tag-pill requirement.

The core image renderer treats every URI as a network image and therefore does not satisfy app-owned local attachment rendering.

The generic file request is not usable through the current managed host path.

These gaps establish deferred product boundaries rather than implementation assignments.

### Actual verification performed on 2026-08-09

`opam exec -- dune runtest` passed against the indexed OCaml architecture before the current worktree removed those files.

The tracked Flutter host tests passed `13` targeted tests with `--no-pub`.

The relevant upstream virtual-list, text-input, and swipe tests passed `38` targeted tests against the existing checkout.

The existing Flutter virtual-list suite includes a `50,000`-item bounded-mount case.

The current worktree deletes `bonsai-flutter.sexp`, so `sync-project --check` and `sync-host --check` currently stop with a missing-manifest error.

Restoring the managed manifest and eliminating generated-host drift are implementation prerequisites.

No current evidence proves the complete product on a physical iPhone, macOS release build, VoiceOver, or real-data profile trace.

### Primary implementation sources

- [`Widget` OCaml API](/Users/rcmerci/gh-repos/bonsai_flutter/ocaml/ui/widget.mli).
- [`Native_widget` OCaml API](/Users/rcmerci/gh-repos/bonsai_flutter/ocaml/ui/native_widget.mli).
- [`Semantics` OCaml API](/Users/rcmerci/gh-repos/bonsai_flutter/ocaml/ui/semantics.mli).
- [`Environment` OCaml API](/Users/rcmerci/gh-repos/bonsai_flutter/ocaml/runtime/environment.mli).
- [`Sparse_extent_list` Flutter implementation](/Users/rcmerci/gh-repos/bonsai_flutter/flutter/packages/bonsai_flutter/lib/src/native_widget/sparse_extent_list.dart).
- [`Pressable` Flutter implementation](/Users/rcmerci/gh-repos/bonsai_flutter/flutter/packages/bonsai_flutter/lib/src/renderer/pressable_host.dart).
- [Flutter accessibility guidance](https://docs.flutter.dev/ui/accessibility).
- [Flutter performance profiling](https://docs.flutter.dev/tools/devtools/performance).

The referenced `bonsai_flutter` files are evidence and dependency code, not implementation targets for this plan.

## Product scope

### Goals

- Match the concept hierarchy and visual rhythm while explicitly omitting Search, styled inline pills, and attachments.
- Keep the complete first-release product widget tree, tokens, routes, state, actions, and semantics intent in OCaml.
- Support offline Capture, plain-source editing, task changes, direct-child expansion, date navigation, and Detail.
- Persist original creation wall time and its time-zone snapshot.
- Keep DataScript and SQLite exclusively inside one OCaml Serial Worker.
- Keep mounted OCaml nodes, Flutter widgets, and database pages bounded through existing known-extent virtualization.
- Preserve known-extent scroll anchors through paging, prepends, edits, task mutations, child expansion, and row-profile changes.
- Make every rendered control functional and accessible through currently supported semantics.
- Restore generator authority and prove iOS and macOS delivery.

### Non-goals

- Preserving the old OCaml public APIs, old schema, Mail-inspired UI, preview cards, Search, or the superseded Dart plan.
- Creating a Dart Journal model, reducer, controller, repository, database, parser, route implementation, or product widget.
- Discovering, opening, reading, migrating, writing, deleting, or cleaning any legacy database path outside `logseq_journal/store.sqlite3`.
- Reading, writing, importing, or synchronizing a real Logseq graph.
- Implementing Search, Search UI, FTS, tag filtering, or mention filtering.
- Parsing, styling, or activating tags and mentions in the first release.
- Implementing intrinsic or arbitrary multiline timeline rows.
- Implementing attachment selection, storage, metadata, thumbnails, or preview.
- Implementing a formal expanded semantics trait or Expand and Collapse semantic actions.
- Implementing live syntax coloring or interactive chips in the focused editor.
- Adding or modifying any `bonsai_flutter` capability for this release.
- Adding an app-specific Flutter fallback for a deferred feature.
- Editing generated `.bonsai-flutter` files directly.

## Target information architecture

```text
OCaml Journal application
├── Journal timeline route
│   ├── Fixed Journal header
│   │   ├── Menu
│   │   ├── Today or selected date
│   │   └── More
│   ├── Known-extent day headers and block rows
│   └── Capture FAB
├── Date selection dialog
├── Capture route
└── Block Detail route
```

Today appears only in the fixed header when the selected context is today.

Older day headings appear in timeline content.

All routes and overlay state are OCaml variants.

Flutter receives pages and overlays only as generic logical nodes and typed events.

## Interaction contract

### Header

| Control | Activation | OCaml result | Back behavior |
| --- | --- | --- | --- |
| Menu | Tap or semantic Tap | Open the OCaml-owned navigation surface | Close the surface first |
| Date context | Activate the full `44 x 44` target | Open OCaml-owned date selection | Cancel returns to the unchanged anchor |
| More | Tap or semantic Tap | Open the OCaml-owned action surface after its item set is confirmed | Dismiss the surface first |

The centered title group is independent from the side controls.

The short handle is decorative and excluded from hit testing and semantics.

### Timeline row

| Region | Activation | OCaml result |
| --- | --- | --- |
| Task check | Tap or checkbox action | Persist Todo or Done without opening Detail. |
| Child disclosure | Tap | Insert or remove a bounded page of direct visible children below the parent. |
| Remaining row | Tap | Open Block Detail. |
| Hashtag or mention source | None beyond the row action | Read, edit, and announce it as ordinary source content. |

The task control, disclosure control, and remaining row are distinct logical and semantic targets.

The disclosure control uses an OCaml-supplied label such as `Show 3 child blocks for Grocery list` or `Hide 3 child blocks for Grocery list`.

The disclosure control uses a textual value of `Collapsed` or `Expanded` and an accurate Tap hint.

It does not claim a native expanded trait or an Expand or Collapse semantic action.

If device acceptance cannot produce one stable and truthful disclosure focus target using existing APIs, the control and count are omitted from the first release.

### Capture and editing

The FAB opens one full-screen OCaml Capture route on compact devices.

Capture accepts source text and optional task state.

Save remains disabled for blank normalized source and while a durable Worker mutation is unresolved.

Cancel closes immediately when clean and asks for Keep editing or Discard when dirty.

The platform text field remains a generic renderer resource, while source text, validation, dirty state, conflict state, Save policy, and route behavior remain OCaml-owned.

Detail shows the complete untruncated source and supports plain-source editing.

## Visual system

### Color tokens

OCaml owns the following semantic token record and passes resolved ARGB values to the renderer.

| Token | Light | Use |
| --- | --- | --- |
| `background` | `#FCFCFD` | Timeline body |
| `header` | `#F9F9FB` | Header surface |
| `text_primary` | `#0D142F` | Entry and title text |
| `text_secondary` | `#656B8F` | Day labels, subtitle, and time |
| `divider` | `#EFF0F4` | Inset separators |
| `action_surface` | `#F1F2F5` | More and other confirmed header action surfaces |
| `handle` | `#7A7F9C` | Decorative short handle |
| `fab` | `#181E34` | Capture action |
| `success` | `#058E46` | Completed-task symbol |

`#656B8F` on `#FCFCFD` has approximately `5.05:1` contrast.

The completed-task icon is non-text information and must exceed `3:1` against its adjacent background.

Dark, high-contrast, pressed, focused, disabled, and error values are explicit OCaml token variants rather than Flutter-derived product colors.

The green, purple, and blue chip palettes are retained only as future visual research and are not first-release tokens.

### Typography

| Role | Size and line height | Weight | Behavior |
| --- | --- | --- | --- |
| Header title | `24 / 30` | `700` | One line |
| Entry | `17 / 22` | `500` | One line with ellipsis in Timeline |
| Subtitle, day, and time | `14 / 20` | `400` | One line with tabular time figures where available |
| Disclosure count | `11 / 16` | `500` | Plain neutral badge or text |

The exact rounded font family remains a device-comparison item because the raster cannot prove it.

Full source remains available in Detail and in the row semantic label when Timeline ellipsizes it.

### Known row profiles

OCaml selects one complete layout profile from `Environment.text_scale` and viewport width.

| Profile | Selection | Block extent | Day-header extent | Layout |
| --- | --- | --- | --- | --- |
| Compact | Viewport width at least `360` and text scale at most `1.3` | `48` | `36` | Source and time share one horizontal row. |
| Adaptive | Any narrower viewport or larger text scale `S` | `ceil(32 + 48 * max(1, S))` | `ceil(24 + 24 * max(1, S))` | Source and time use separate conservative lines. |

The profile extents are exact `Sparse_extent_list` inputs rather than measured estimates.

Tests at text scales `1.0`, `1.3`, `2.0`, and `3.2` must prove that source, time, task, disclosure, and divider do not clip or overlap.

If an existing renderer or font configuration violates an extent, the OCaml token is increased for the entire profile rather than adding measurement code.

### Geometry

| Token | Value | Notes |
| --- | --- | --- |
| Standard content leading | `28` | Use `24` on narrow width. |
| Divider inset | `18` | One physical pixel where device pixel ratio permits. |
| Header visual action | `32` | Wrap in a `44` target. |
| Date target | At least `44 x 44` | Center independently. |
| Task target | At least `44 x 44` | Keep the visual check smaller. |
| Disclosure target | At least `44 x 44` | Keep count and glyph inside one target. |
| FAB visual | `48` | Use a `56` target. |
| Bottom padding | Safe bottom plus FAB footprint and spacing | Ensure the final row scrolls clear. |

The spacing grid is `4, 8, 12, 16, 20, 24, 28`.

## Application architecture

```text
Flutter managed host
├── Generated main and runtime mount
├── Existing renderer
│   ├── Widget.text, Flex, Stack, SafeArea, Pressable, and Semantics
│   ├── Sparse_extent_list with known extents
│   ├── Navigator, dialog, and text input
│   └── Existing focus, IME, paint, and scroll resources
└── Existing mechanical application adapter
    ├── Application Support root
    ├── Calendar, locale, time-zone, and environment facts
    └── Lifecycle forwarding

OCaml Bonsai application
├── Visual tokens and known layout profiles
├── Header, rows, task control, disclosure, and FAB
├── Timeline window and route state
├── Capture and Detail reducers
├── Textual semantics and actions
└── Typed Worker effects

OCaml Serial Worker
├── DataScript database
├── App-private SQLite connection
├── Schema and store identity
├── Feed and direct-child paging
├── Capture, edit, task, and child mutations
├── Revision and mutation fencing
└── Recovery and lifecycle ownership

Application Support/logseq_journal/store.sqlite3
```

The renderer never receives the complete database or an unbounded timeline.

The OCaml application sends only the current known-extent logical window and overscan.

The Flutter host contains no Journal-aware state or rendering branch.

## Proposed source layout

### Project OCaml application

```text
/Users/rcmerci/gh-repos/logseq_journal/app/
├── application.ml
├── application.mli
├── journal_model.ml
├── journal_model.mli
├── journal_time.ml
├── journal_time.mli
├── journal_schema.ml
├── journal_schema.mli
├── journal_repository.ml
├── journal_repository.mli
├── journal_worker.ml
├── journal_worker.mli
├── journal_timeline_state.ml
├── journal_timeline_state.mli
├── journal_visual_tokens.ml
├── journal_visual_tokens.mli
├── journal_header.ml
├── journal_header.mli
├── journal_row.ml
├── journal_row.mli
├── journal_timeline.ml
├── journal_timeline.mli
├── journal_capture.ml
├── journal_capture.mli
├── journal_detail.ml
├── journal_detail.mli
├── journal_routes.ml
├── journal_routes.mli
├── journal_startup.ml
├── journal_startup.mli
├── journal_platform.ml
├── journal_platform.mli
├── journal_process_recovery.ml
├── journal_process_recovery.mli
├── journal_storage.ml
├── journal_storage.mli
├── journal_storage_path.ml
├── journal_storage_path.mli
├── journal_validation.ml
├── journal_validation.mli
└── dune
```

`application.ml` wires the modules and must not become a monolithic repository, parser, or renderer.

There is no first-release inline-token, attachment-store, attachment-preview, or Search module.

### Project OCaml tests

```text
/Users/rcmerci/gh-repos/logseq_journal/test/
├── application_view_test.ml
├── source_boundary_test.ml
├── journal_model_test.ml
├── journal_time_test.ml
├── journal_schema_test.ml
├── journal_repository_test.ml
├── journal_worker_test.ml
├── journal_timeline_state_test.ml
├── journal_routes_test.ml
├── journal_semantics_test.ml
├── journal_adaptive_test.ml
├── journal_platform_test.ml
├── journal_storage_test.ml
├── journal_recovery_test.ml
└── dune
```

### Project Flutter allowlist

```text
/Users/rcmerci/gh-repos/logseq_journal/flutter/
├── lib/main.dart
├── lib/application_host_adapter.dart
├── test/widget_test.dart
├── test/application_host_adapter_test.dart
├── test/journal_runtime_golden_test.dart
└── integration_test/journal_runtime_flow_test.dart
```

`flutter/lib/main.dart` and `flutter/test/widget_test.dart` remain generator-owned.

The application adapter contains only startup platform facts and the existing calendar or lifecycle bridge.

The golden and integration harnesses must start the real compiled OCaml runtime rather than recreate Journal UI in Dart.

The following project paths are forbidden in the target tree.

```text
flutter/lib/app/
flutter/lib/core/
flutter/lib/features/
flutter/test/app/
flutter/test/features/
flutter/test/support/fake_journal_repository.dart
```

### Read-only framework baseline

The following existing dependency files define the supported first-release boundary.

```text
/Users/rcmerci/gh-repos/bonsai_flutter/ocaml/ui/widget.mli
/Users/rcmerci/gh-repos/bonsai_flutter/ocaml/ui/native_widget.mli
/Users/rcmerci/gh-repos/bonsai_flutter/ocaml/ui/semantics.mli
/Users/rcmerci/gh-repos/bonsai_flutter/ocaml/runtime/environment.mli
/Users/rcmerci/gh-repos/bonsai_flutter/flutter/packages/bonsai_flutter/test/virtual_list_test.dart
/Users/rcmerci/gh-repos/bonsai_flutter/flutter/packages/bonsai_flutter/test/text_input_host_test.dart
/Users/rcmerci/gh-repos/bonsai_flutter/flutter/packages/bonsai_flutter/test/pressable_test.dart
```

No task in this plan modifies any file under `/Users/rcmerci/gh-repos/bonsai_flutter`.

No task edits the generated `/Users/rcmerci/gh-repos/logseq_journal/.bonsai-flutter` mirror directly.

## Domain and persistence model

### Source of truth

Block source text is canonical and is displayed literally in the first release.

Explicit sibling order is canonical for display ordering.

Creation time is immutable metadata and does not replace explicit ordering.

Task state, hierarchy, revision, and mutation identity are canonical domain facts.

### Core OCaml domain contracts

| Contract | Required fields or states |
| --- | --- |
| Journal entry | ID, day, parent ID, sibling order, source, task state, child count, creation time, revision, and last mutation ID |
| Creation time | Instant Unix milliseconds, local day, local minute of day, time-zone ID, and UTC offset seconds |
| Route | Timeline, Capture, Detail, or a confirmed Menu or More surface |
| Timeline slot | Day header, top-level block row, direct-child row with depth, or bounded continuation |
| Layout profile | Compact or Adaptive with exact row and day-header extents |
| Mutation state | Idle, admitted, saving, committed, conflict, failed, or recovery-only |

OCaml validates byte-safe UTF-8 source boundaries.

The generic text-input boundary converts deliberately between OCaml UTF-8 offsets and Flutter UTF-16 selection or composing offsets.

### DataScript schema

| Entity | Purpose | Important attributes |
| --- | --- | --- |
| Store metadata | Exact store identity and schema version | Store ID and schema version |
| Journal page | Journal-day identity and descending day seek | Page ID, day, and title |
| Block | Canonical source, hierarchy, order, task, creation time, and revision | Block ID, page reference, parent reference, order, source, task, creation instant, local day, local minute, zone ID, offset, revision, and mutation ID |

The schema starts at version `1` under a new store identity.

The exact database relative path is `logseq_journal/store.sqlite3` and is defined only in OCaml.

The app may create and reopen that exact canonical store on every launch.

Legacy database paths, including `logseq_journal/journal.sqlite3`, are never discovered or managed.

The Dart startup payload supplies the canonical Application Support root but does not supply database relative path, schema version, or migration policy.

The schema contains no attachment or Search entity, attribute, index, migration, or dormant placeholder.

### Ordering and creation time

Journal days sort descending by stored local day.

Top-level entries within a day sort ascending by explicit sibling order and stable ID.

Direct children sort ascending by explicit sibling order and stable ID.

Capture and Create child snapshot platform time at action admission and persist the complete creation-time record atomically with the new block.

OCaml formats the visible time from `local_minute_of_day` as `HH:mm`.

Changing the device time zone never changes the displayed creation time of an existing entry.

Entries with invalid creation metadata fail schema admission or omit time under an explicitly tested corrupt-record surface rather than fabricating `00:00`.

### Plain source policy

Timeline renders the complete source through `Widget.text` with `max_lines = 1` and ellipsis.

Hashtag, mention, emoji, and delimiter characters remain literal source bytes.

The first release performs no token parsing, palette assignment, token navigation, or token-specific semantics.

Detail exposes the complete source for reading and editing.

## Timeline projection and scrolling

The OCaml repository returns bounded day and block pages.

`Journal_timeline_state` flattens those pages into stable slots and applies the set of expanded block IDs.

No Search boundary, preview card, attachment row, or deferred capability placeholder is part of the sequence.

OCaml selects Compact or Adaptive profile from the current environment.

`Sparse_extent_list` receives the exact default block extent and exact day-header overrides for that profile.

Direct-child rows use the same block extent as top-level rows and are inserted immediately after their parent.

The OCaml Bonsai graph retains at most `512` logical timeline slots and materializes at most `40` supplied rows including overscan.

The renderer emits the existing coalesced visible-range event, and OCaml uses it to request the next bounded logical window or database page.

Top insertion, page append, task replacement, child expansion, child collapse, route return, and profile changes preserve the first stable visible slot where the existing sparse-list contract supports it.

Tests must verify the current renderer behavior rather than assume undocumented anchor guarantees.

If a required anchor case fails with current public APIs, the product action must use an explicit safe reset or be deferred instead of patching the renderer.

Mounted child count, OCaml slot window, continuation count, and database page size have explicit upper bounds.

## Accessibility contract

OCaml supplies the complete supported semantic label, hint, value, role, checked state, sort order, and action set for each product node.

Flutter maps those supported values without deriving Journal meaning.

Day labels are headings.

Task controls expose checked state and one dedicated activation target.

Disclosure controls expose Button role, Tap action, stateful Show or Hide label, Collapsed or Expanded textual value, and an accurate hint.

Rows expose the full source and creation time in their semantic label even when visual text is ellipsized.

The task control, disclosure control, and row action must not duplicate labels or actions.

Every visual icon target is at least `44 x 44` logical pixels, and Capture is at least `56 x 56`.

At text scales through `3.2`, the Adaptive profile must prevent clipping and overlap while retaining one-line source plus full Detail and semantics access.

Reduced motion disables nonessential existing interpolation but preserves final state and controls.

VoiceOver, keyboard navigation, high contrast, dark mode, and focus restoration are release gates within current API support.

Formal expanded state, separate Expand or Collapse actions, semantics merge or exclusion controls, arbitrary multiline Timeline, and inline-token semantics remain deferred.

## Storage and platform security boundary

OCaml chooses and validates the exact app-owned database path below the canonical Application Support root.

The platform adapter only resolves the operating-system Application Support root and returns bounded calendar, locale, time-zone, environment, and lifecycle facts.

The OCaml Worker owns database containment, canonicalization, transaction ordering, recovery, and shutdown.

The application has no graph directory picker, file picker, media picker, attachment directory, security-scoped bookmark, file presenter, graph watcher, graph import, or graph synchronization path.

## Requirement-to-evidence matrix

| Requirement | Automated evidence | Manual or profile evidence |
| --- | --- | --- |
| OCaml ownership | OCaml root behavior tests and project source-boundary test | Release diff inspection |
| Existing renderer only | Dependency immutability check and forbidden native-widget audit | Framework pin and mirror review |
| Header hierarchy | OCaml logical tree test and real-runtime golden | Normalized screenshot overlay |
| Search omission | Negative logical tree, route, Worker, and source audits | Golden documents accepted omission |
| Plain source | Domain preservation and `Widget.text` logical tests | Compare literal tags, mentions, emoji, and ellipsis |
| Known row profiles | OCaml profile tests and real-runtime goldens at four scales | Device Dynamic Type review |
| Lazy timeline | `10,000` durable records, `512` rolling slots, `40` supplied rows, plus a separate `50,000` synthetic stress case | Profile fling trace |
| Child disclosure | OCaml projection and mutation tests plus current semantics tree test | VoiceOver Show or Hide announcement and stable focus |
| Task state | Repository mutation and OCaml action tests | Checked-state VoiceOver review |
| Creation time | Instant and zone-snapshot persistence, DST, restart, and formatting tests | Time-zone change review |
| Capture and Detail | Route, IME, conflict, dirty-cancel, and durable mutation tests | Chinese and Japanese device IME matrix |
| Durability | Real temporary SQLite restart and crash-boundary tests | Forced restart exercise |
| Deferred scope | Negative attachment, picker, image, token parser, and renderer-extension audits | Visual omission review |
| Generator authority | `sync-project --check` and `sync-host --check` | Generated diff review |
| iOS and macOS | Host and compiled-runtime integration suites | Signed physical iPhone and macOS release runs |

## Implementation plan

Use `@Test-Driven Development (TDD)` for every implementation task below.

Within each behavior tranche, write the complete happy-path, edge, and pathological suite, run it, confirm the intended RED failure, implement only the missing behavior, run GREEN, refactor, and run the same suite again.

The user granted permission on 2026-08-09 to modify `/Users/rcmerci/gh-repos/logseq_journal/dune-project`, `/Users/rcmerci/gh-repos/logseq_journal/app/dune`, and `/Users/rcmerci/gh-repos/logseq_journal/test/dune`.

No task modifies an upstream `bonsai_flutter` file.

### Phase 0: Lock ownership and restore the OCaml application baseline

#### Task 1: Record the product and ownership authority

Files:

- Read `/Users/rcmerci/gh-repos/logseq_journal/docs/agent-guide/005-journal-timeline-ui.md`.
- Do not modify implementation files in this task.

Steps:

1. Record OCaml as the owner of all Journal UI and logic.
2. Record that the first release uses only the current pinned public `bonsai_flutter` API.
3. Record the five deferred capabilities and every dependent accepted omission.
4. Record app-owned SQLite, no real Logseq graph, original creation wall time, no Search, no attachment slice, no legacy-database handling, and the project Dune authorization.
5. Record Menu and More items as the only unresolved product decision.
6. Treat any request to add a missing renderer capability as a new PRD decision.

Expected result: Every later task has one explicit owner and no hidden renderer, compatibility, or deferred-feature requirement.

#### Task 2: Write the source-boundary RED test

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/test/source_boundary_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/dune`.

Steps:

1. Assert that `Application.app`, the OCaml repository, the Serial Worker, and DataScript-backed storage exist.
2. Assert that project Flutter production code contains no `app`, `core`, or `features` product directory.
3. Assert that `flutter/pubspec.yaml` contains no `sqlite3`, `sqflite`, or `drift` product database dependency.
4. Assert that project Dart production files contain no Journal controller, repository, database, domain model, parser, or product page implementation.
5. Assert that no project or generated file registers a new app-specific native widget.
6. Assert that no first-release source contains attachment, picker, local-image, inline-token parser, measured-list, or formal-expanded capability implementation.
7. Run `opam exec -- dune runtest` and confirm RED against the current pure-Flutter worktree.

Expected RED result: The test reports the exact superseded Dart product paths and missing OCaml ownership without failing for a test syntax error.

#### Task 3: Write the OCaml root ownership RED test

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/dune`.

Steps:

1. Render `Application.app` through `bonsai_flutter_test` with a fixed environment and bounded Worker fixture.
2. Assert one header, Today context, Menu, More, known-extent timeline, and Capture action.
3. Assert that Search, styled token pills, attachment controls, thumbnails, and preview-first cards are absent.
4. Activate a row, task control, disclosure, date target, and Capture action through real OCaml handlers.
5. Assert the resulting OCaml route, expansion state, or mutation intent.
6. Run the focused test and confirm RED because the screenshot-directed OCaml root is not implemented.

Expected RED result: The test fails for missing target behavior while proving the real OCaml application boundary is under test.

#### Task 4: Restore the generated host and indexed OCaml baseline

Files:

- Restore and retain `/Users/rcmerci/gh-repos/logseq_journal/bonsai-flutter.sexp`.
- Restore and retain `/Users/rcmerci/gh-repos/logseq_journal/app/` and `/Users/rcmerci/gh-repos/logseq_journal/test/` as product source roots.
- Retain `/Users/rcmerci/gh-repos/logseq_journal/flutter/lib/application_host_adapter.dart`.
- Regenerate `/Users/rcmerci/gh-repos/logseq_journal/flutter/lib/main.dart` and `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/widget_test.dart`.
- Remove `/Users/rcmerci/gh-repos/logseq_journal/flutter/lib/app/`.
- Remove `/Users/rcmerci/gh-repos/logseq_journal/flutter/lib/core/`.
- Remove `/Users/rcmerci/gh-repos/logseq_journal/flutter/lib/features/`.
- Remove Dart product tests under `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/app/`, `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/features/`, and `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/support/`.

Steps:

1. Capture the exact dirty index and worktree with `git status --short`.
2. Verify every planned removal belongs to the superseded pure-Flutter direction and preserve unrelated user work.
3. Restore the indexed managed manifest, Worker, storage, platform, recovery, and application baseline.
4. Remove Dart product-layer source and dependencies without leaving stubs or fallbacks.
5. Run `opam exec -- bonsai-flutter sync-project` and `opam exec -- bonsai-flutter sync-host` without changing the dependency source.
6. Run the source-boundary test until its architecture assertions are GREEN.
7. Run the generated-host construction test.
8. Refactor only after both gates pass, then rerun them.

Expected GREEN result: The repository has one OCaml product runtime, one restored manifest, one mechanical generated Flutter host, and no local renderer extension.

#### Task 5: Write obsolete Search and Mail-model RED tests

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_repository_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_worker_test.ml`.

Steps:

1. Assert that `Search_route`, `pending_search`, `Search_boundary`, Worker Search requests, repository search functions, and visible Search actions are absent.
2. Assert that preview-first morphing cards and `Load_preview` behavior are absent.
3. Assert that direct-child disclosure and Detail are the only supported hierarchy interactions.
4. Run the focused suites and confirm RED because obsolete behavior still exists in the indexed baseline.

Expected RED result: The tests identify Search and preview-first behavior as the failing obsolete paths.

#### Task 6: Remove Search and the obsolete Mail interaction model

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_repository.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_worker.ml` and `.mli`.
- Replace `/Users/rcmerci/gh-repos/logseq_journal/app/journal_feed_state.ml` and `.mli` with `/Users/rcmerci/gh-repos/logseq_journal/app/journal_timeline_state.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/dune` and `/Users/rcmerci/gh-repos/logseq_journal/test/dune`.

Steps:

1. Remove Search types, requests, repository queries, route state, and visible actions rather than disabling them.
2. Remove preview types, `Load_preview`, morphing-card state, and obsolete tests.
3. Retain bounded feed, Detail, and direct-child paging concepts.
4. Run the focused and full OCaml suites until GREEN.
5. Refactor the resulting state boundaries and rerun the suites.

Expected GREEN result: Search and preview-first UI no longer exist in any product path.

### Phase 1: Build the OCaml domain, store, repository, and Worker

#### Task 7: Write the OCaml model and creation-time RED suite

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/test/journal_model_test.ml`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/test/journal_time_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/dune`.

Steps:

1. Test stable identity, page, parent, explicit order, source, task state, child count, revision, and mutation ID through public behavior.
2. Test creation admission around midnight, DST gaps and folds, device time-zone changes, invalid zone data, and restart.
3. Test immutable display time from stored local minute and original zone snapshot.
4. Test empty, huge, NUL-containing, malformed UTF-8, emoji, combining, bidi, hashtag, and mention source admission.
5. Assert that no inline-token or attachment model is created.
6. Run the focused suites and confirm RED for missing clean-slate contracts.

Expected RED result: The indexed model cannot preserve the complete creation-time contract and still contains superseded assumptions.

#### Task 8: Implement and verify the OCaml model and time policy

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_model.ml` and `.mli`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_time.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_validation.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/dune`.

Steps:

1. Implement the minimum immutable entry, creation-time, task, hierarchy, revision, and mutation types required by the RED suite.
2. Preserve literal source without parsing tokens.
3. Admit one action-time snapshot containing instant, local day, local minute, time-zone ID, and UTC offset.
4. Format visible `HH:mm` in OCaml from stored creation metadata.
5. Run focused tests until GREEN, refactor, and rerun focused plus full OCaml suites.

Expected GREEN result: OCaml owns canonical source, hierarchy, task state, and immutable original creation time without deferred-feature fields.

#### Task 9: Write the clean-store and schema RED suite

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/test/journal_schema_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_storage_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_recovery_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/dune`.

Steps:

1. Create a real temporary app-private DataScript SQLite store.
2. Assert exact store identity, schema version `1`, and relative path `logseq_journal/store.sqlite3`.
3. Persist creation-time metadata, close, reopen, and verify it.
4. Place a legacy `logseq_journal/journal.sqlite3` beside it and assert that the application never opens, changes, removes, or reports it.
5. Assert that the schema contains no Search, attachment, migration, or legacy-fallback attribute.
6. Test corrupt canonical store, schema mismatch, crash boundary, database busy, and recovery-only startup.
7. Run the focused suites and confirm RED against the indexed schema and path.

Expected RED result: The old store identity or incomplete time schema fails while the legacy file remains untouched.

#### Task 10: Implement and verify the clean OCaml store

Files:

- Replace `/Users/rcmerci/gh-repos/logseq_journal/app/journal_schema.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_startup.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_storage.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_storage_path.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_process_recovery.ml` and `.mli`.

Steps:

1. Define the minimum schema for store metadata, pages, and blocks.
2. Create or reopen only `logseq_journal/store.sqlite3` below the canonical support root.
3. Persist the complete creation-time record atomically with Capture and Create child.
4. Reject unsafe canonical paths and never scan for legacy stores.
5. Keep recovery deterministic and scoped only to the canonical store.
6. Run focused tests until GREEN, refactor, and rerun focused plus full OCaml suites.

Expected GREEN result: The app has one OCaml-owned canonical store and no legacy, Search, or attachment behavior.

#### Task 11: Write repository RED suites

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/test/journal_repository_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/dune`.

Steps:

1. Test bounded descending day paging and ascending compound block cursors.
2. Test equal sibling positions, stable-ID tie-breaking, empty days, day continuation, direct-child paging, and deleted parents.
3. Test Capture, Create child, edit, task transition, duplicate mutation, expected-revision conflict, and close or reopen.
4. Test literal source round trips for tags, mentions, emoji, combining characters, bidi text, and long source.
5. Assert that repository behavior has no Search, preview, token index, or attachment path.
6. Run the focused suite and confirm RED for missing target behavior.

Expected RED result: The repository cannot yet provide the complete first-release timeline and mutation contract.

#### Task 12: Implement and verify the repository

Files:

- Replace `/Users/rcmerci/gh-repos/logseq_journal/app/journal_repository.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_schema.ml` and `.mli` only if the RED behavior proves a schema requirement.

Steps:

1. Implement bounded page, block, child, Detail, cursor, and mutation queries.
2. Order through explicit sibling order and stable ID.
3. Implement idempotent mutation planning and revision compare-and-swap.
4. Return literal source and immutable creation metadata.
5. Run focused tests until GREEN, refactor, and rerun focused plus full OCaml suites.

Expected GREEN result: Repository behavior is deterministic, bounded, durable, and free of deferred feature paths.

#### Task 13: Write the Serial Worker RED suite

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/test/journal_worker_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/dune`.

Steps:

1. Test one exclusive database session, bounded startup, feed pages, child pages, Detail, mutations, and status.
2. Test request generations, late-response rejection, duplicate mutations, shutdown, runtime replacement, and recovery-only mode.
3. Test response byte bounds, oversized source handling, storage failure, and calendar-generation fencing.
4. Assert that Worker request and response variants contain no Search, preview, attachment, picker, or token parser path.
5. Run the focused suite and confirm RED against the indexed Worker contract.

Expected RED result: The Worker still exposes obsolete variants or lacks the creation-time and no-deferred-feature contract.

#### Task 14: Implement and verify the Serial Worker

Files:

- Replace `/Users/rcmerci/gh-repos/logseq_journal/app/journal_worker.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_startup.ml` and `.mli` where Worker lifecycle requires it.

Steps:

1. Keep one long-lived OCaml Worker service and one SQLite connection.
2. Route only supported repository requests through typed variants.
3. Fence stale generations and preserve mutation idempotency.
4. Bound every response and transition deterministically into recovery-only mode on unsafe storage state.
5. Run focused tests until GREEN, refactor, and rerun focused plus full OCaml suites.

Expected GREEN result: One OCaml Worker owns all first-release persistence behavior with no Search or attachment surface.

### Phase 2: Build the OCaml platform, visual, timeline, and route layers

#### Task 15: Write the startup and calendar platform RED suite

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_platform_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_storage_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/application_host_adapter_test.dart`.

Steps:

1. Test bounded Application Support root, calendar generation, instant, local day, local minute, time-zone ID, UTC offset, locale, and lifecycle generation.
2. Test missing platform facts, stale generations, malformed offsets, DST folds, time-zone changes, backgrounding, and runtime replacement.
3. Assert that the adapter never supplies database relative path, schema, migration policy, route, token, attachment, or Journal mutation.
4. Run focused OCaml and Dart suites and confirm RED for missing time facts or excess adapter behavior.

Expected RED result: The boundary fails only for required mechanical facts or forbidden product ownership.

#### Task 16: Implement and verify the thin platform adapter

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_platform.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/flutter/lib/application_host_adapter.dart` only for proven mechanical facts.
- Modify existing Apple host files only when a tested operating-system fact cannot be delivered otherwise.

Steps:

1. Expose the minimum bounded startup, calendar, locale, time-zone, environment, and lifecycle payload.
2. Keep database path, schema, creation-time formatting, layout profiles, and Journal state in OCaml.
3. Do not add picker, local-image, token, timeline, or product-action code.
4. Run focused tests until GREEN, refactor codec duplication, and rerun OCaml, Dart, sync-project, and sync-host checks.

Expected GREEN result: The adapter is mechanical, bounded, and free of product policy.

#### Task 17: Write OCaml visual-token and header RED tests

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/test/journal_adaptive_test.ml`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/journal_runtime_golden_test.dart` with a real-runtime failing header case.

Steps:

1. Test all light, dark, high-contrast, pressed, focused, disabled, and error tokens as rendered behavior.
2. Test safe-area header geometry, independent center group, Today or selected date, subtitle, Menu, More, decorative handle, and absent Search.
3. Test narrow and wide viewport behavior without changing control semantics.
4. Start the real OCaml runtime and record the expected RED golden mismatch for the header.
5. Run the focused suites and confirm RED for missing target visuals rather than harness failure.

Expected RED result: The OCaml root lacks the required visual system and header hierarchy.

#### Task 18: Implement and verify OCaml tokens and header

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_visual_tokens.ml` and `.mli`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_header.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/dune`.

Steps:

1. Define colors, typography, spacing, known row profiles, motion, and hit-region tokens in OCaml.
2. Compose the header with existing Flex, Stack, SafeArea, decoration, text, and Pressable primitives.
3. Use OCaml text or shape glyphs and do not add a Dart product icon widget.
4. Keep Search absent and the handle decorative.
5. Run focused tests and the header golden until GREEN, refactor, and rerun them.

Expected GREEN result: The real OCaml header matches the accepted first-release geometry through existing renderer primitives.

#### Task 19: Write OCaml row and semantics RED tests

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/test/journal_semantics_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_adaptive_test.ml`.
- Extend `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/journal_runtime_golden_test.dart` with row cases.

Steps:

1. Test plain source, literal hashtag, literal mention, emoji, completion, child count, creation time, missing time, very long source, and corrupt source behavior.
2. Test Compact and Adaptive rows at viewport widths `320`, `390`, `744`, and `1200` and text scales `1.0`, `1.3`, `2.0`, and `3.2`.
3. Test exact profile extents, one-line ellipsis, full Detail source, and full row semantic label.
4. Test independent task, disclosure, and remaining-row activation precedence.
5. Test checked state and truthful Show or Hide disclosure label, textual state value, hint, and Tap action without asserting a formal expanded trait.
6. Assert that styled pills, token-specific actions, thumbnail, attachment action, and attachment semantics are absent.
7. Run all focused tests and real-runtime row goldens and confirm RED.

Expected RED result: Existing OCaml UI cannot yet render the fixed-profile row contract.

#### Task 20: Implement and verify OCaml rows

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_row.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_visual_tokens.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/dune`.

Steps:

1. Render literal source through `Widget.text` with one line and ellipsis.
2. Build Compact horizontal rows and Adaptive two-band rows from existing OCaml primitives.
3. Reserve the time slot and preserve full source in Detail and semantics.
4. Build task, disclosure, remaining-row, and divider targets entirely in OCaml.
5. Use the current semantics fields only and never encode a fake formal expanded state.
6. Run focused tests and row goldens until GREEN, refactor, and rerun them.

Expected GREEN result: Rows preserve the target hierarchy with explicit accepted omissions and no new renderer capability.

#### Task 21: Write OCaml timeline and known-extent anchoring RED tests

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/test/journal_timeline_state_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.
- Extend `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/journal_runtime_golden_test.dart` with timeline cases.

Steps:

1. Test days descending, entries ascending, stable ties, Today suppression, day headings, direct-child insertion, and continuation slots.
2. Test bounded windows and visible-range catch-up across a `10,000`-record durable corpus and a separate `50,000`-row synthetic stress sequence.
3. Assert at most `512` retained OCaml slots and at most `40` supplied rows including overscan.
4. Test exact default and override extents for every profile.
5. Test prepend, page append, task replacement, expansion, collapse, profile change, and return from Detail using current sparse-list behavior.
6. Test final-row clearance below the FAB and safe-area bottom.
7. Assert that no variable-height estimate, measurement cache, image remeasurement, or renderer extension event exists.
8. Run focused tests and confirm RED for missing OCaml projection or current-API integration.

Expected RED result: The application lacks the known-extent timeline while the existing native-list contract remains unchanged.

#### Task 22: Implement and verify the OCaml timeline

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_timeline_state.ml` and `.mli`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_timeline.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/dune`.

Steps:

1. Flatten bounded repository pages and expanded direct children into stable slots.
2. Select the complete row profile in OCaml from the environment.
3. Feed total count, first index, exact default extent, day-header overrides, transition policy, current items, and overscan to existing `Sparse_extent_list`.
4. Page from the existing visible-range callback and discard stale generations.
5. Apply only anchor behavior already verified through the pinned renderer.
6. Use a safe reset or defer a mutation if a required anchor cannot be preserved with current APIs.
7. Run focused tests and timeline goldens until GREEN, refactor, and rerun them.

Expected GREEN result: OCaml owns the complete known-extent timeline while Flutter executes only its existing sparse-list mechanics.

#### Task 23: Write OCaml route and mutation RED tests

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/test/journal_routes_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_worker_test.ml`.

Steps:

1. Test date selection, Capture, dirty cancel, task toggle, direct-child creation, disclosure, Detail, edit conflict, retry, Back order, and anchor restoration.
2. Test rapid repeated actions, stale Worker responses, missing block, deleted parent, backgrounding, and runtime replacement.
3. Test that Capture and Detail have no attachment action or token-specific interaction.
4. Test plain IME source behavior with CJK, emoji, combining marks, selection, paste, undo, and conflict while composing.
5. Run the focused suites and confirm RED for missing route and mutation behavior.

Expected RED result: The OCaml root cannot yet complete the first-release interaction flow.

#### Task 24: Implement and verify OCaml routes and mutations

Files:

- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_capture.ml` and `.mli`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_detail.ml` and `.mli`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/app/journal_routes.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/dune`.

Steps:

1. Implement Timeline, date dialog, Capture, and Detail as OCaml route variants and reducers.
2. Invoke only existing generic text input, dialog, Navigator, Pressable, and semantics capabilities.
3. Keep Save, conflict, retry, dirty cancel, Back behavior, task state, and child state in OCaml.
4. Keep attachment and token interaction absent.
5. Run focused tests until GREEN, refactor, and rerun focused plus full OCaml suites.

Expected GREEN result: Every implemented first-release interaction completes through OCaml state and the Worker.

#### Task 25: Write Menu and More RED tests after product confirmation

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/journal_routes_test.ml`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.

Steps:

1. Stop until the exact Menu and More item sets, ordering, labels, enabled states, and destinations are confirmed.
2. Test each confirmed item through its public OCaml route or action behavior.
3. Test dismissal, Back order, unavailable state, keyboard activation, and semantics.
4. Run the focused suite and confirm RED for the missing confirmed behavior.

Expected RED result: Only confirmed Menu and More behavior is missing.

#### Task 26: Implement and verify Menu and More

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_routes.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_header.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` and `.mli`.

Steps:

1. Implement only the confirmed items and destinations in OCaml.
2. Compose the surface from existing overlay, dialog, navigation, text, and Pressable primitives.
3. Add no placeholder, disabled future capability, or Dart route.
4. Run focused tests until GREEN, refactor, and rerun them.

Expected GREEN result: Menu and More are functional, truthful, and OCaml-owned.

### Phase 3: Accessibility, resilience, and release proof

#### Task 27: Write final semantics and adaptive RED suites

Files:

- Expand `/Users/rcmerci/gh-repos/logseq_journal/test/journal_semantics_test.ml`.
- Expand `/Users/rcmerci/gh-repos/logseq_journal/test/journal_adaptive_test.ml`.
- Expand `/Users/rcmerci/gh-repos/logseq_journal/test/application_view_test.ml`.

Steps:

1. Test headings, checked state, full-source labels, disclosure Show or Hide text, textual state value, Tap action, focus order, live regions, and no duplicate logical actions.
2. Test viewport widths `320`, `390`, `744`, and `1200` with text scales `1.0`, `1.3`, `2.0`, and `3.2`.
3. Test dark, high contrast, reduced motion, keyboard-only, RTL, safe-area, and macOS narrow-window behavior.
4. Test loading, empty, recovery-only, conflict, corrupt record, and storage-failure surfaces.
5. Assert the absence of formal expanded state, Expand or Collapse actions, styled tokens, and attachment semantics.
6. Run all suites and confirm RED for missing application behavior rather than missing framework features.

Expected RED result: Remaining failures identify only OCaml-owned semantics, layout profiles, or truthful error states.

#### Task 28: Implement accessibility, adaptive behavior, and truthful failures

Files:

- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_visual_tokens.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_header.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_row.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/journal_timeline.ml` and `.mli`.
- Modify `/Users/rcmerci/gh-repos/logseq_journal/app/application.ml` and `.mli`.

Steps:

1. Supply all supported semantics and adaptive profile values from OCaml.
2. Increase the entire known row profile when tests prove clipping rather than adding intrinsic measurement.
3. Restore focus by stable logical ID after route and supported list changes.
4. If disclosure produces duplicate or untruthful native semantics, omit the disclosure control for the release and keep the row route available.
5. Render explicit loading, empty, recovery-only, conflict, corrupt-record, and storage-failure states.
6. Run focused and full OCaml suites until GREEN, refactor, and rerun them.

Expected GREEN result: The product is accessible and truthful within the pinned public renderer boundary.

#### Task 29: Complete real-runtime integration and golden proof

Files:

- Complete `/Users/rcmerci/gh-repos/logseq_journal/flutter/test/journal_runtime_golden_test.dart`.
- Add `/Users/rcmerci/gh-repos/logseq_journal/flutter/integration_test/journal_runtime_flow_test.dart`.

Steps:

1. Start the compiled OCaml runtime rather than a fake Dart repository or Dart widget tree.
2. Exercise normal, task, direct-child, long-source, Today boundary, older-day, Capture, Detail, loading, empty, and error cases.
3. Exercise Compact and Adaptive profiles, narrow and wide widths, dark mode, high contrast, reduced motion, and safe-area variants.
4. Normalize the concept-artboard scale and compare header, baselines, dividers, columns, task control, disclosure, FAB, and bottom clearance within `2` logical pixels at normal scale.
5. Record Search, styled tag pills, thumbnail, and attachment interaction as accepted omissions.
6. Verify project Dart contains only harness mechanics and no product constants or behavior.
7. Run the golden and integration suites twice after refactor.

Expected result: Real OCaml runtime output matches the declared reduced milestone without a shadow Dart implementation.

#### Task 30: Prove large-data and existing-renderer performance

Files:

- Add a bounded-data scenario to `/Users/rcmerci/gh-repos/logseq_journal/test/journal_timeline_state_test.ml`.
- Extend `/Users/rcmerci/gh-repos/logseq_journal/flutter/integration_test/journal_runtime_flow_test.dart` only with mechanical measurements.

Steps:

1. Seed `10,000` durable records across representative days through the OCaml Worker as the product release corpus.
2. Run a separate `50,000`-row synthetic sparse-list stress sequence and label it stress evidence rather than a production service-level promise.
3. Include long one-line source, equal-order ties, tasks, and bounded direct children without attachments or variable heights.
4. Record durable query latency, Worker payload size, OCaml rolling-slot count, supplied-row count, Flutter mounted-node count, frame size, UI frame time, raster frame time, and memory.
5. Require at most `512` retained OCaml slots and at most `40` supplied rows including overscan.
6. Exercise cold load, fast fling, prepend, page append, task replacement, expansion, profile change, and route return.
7. Run release or profile builds on representative macOS and physical iPhone hardware.
8. Record explicit budgets and fail the release when they are exceeded.

Expected result: Existing known-extent virtualization, not a microbenchmark or new renderer, meets the recorded device budgets.

#### Task 31: Run physical iPhone and macOS acceptance

Files:

- Record results in the implementation pull request or a dated report under `/Users/rcmerci/gh-repos/logseq_journal/docs/agent-guide/`.

Steps:

1. Launch a signed physical iPhone build and a release macOS build.
2. Exercise Chinese and Japanese composition, emoji, combining marks, selection, paste, undo, rapid edits, backgrounding, and route restoration.
3. Exercise VoiceOver headings, task state, full-source row labels, disclosure Show or Hide announcement, Tap action, reading order, hit regions, and focus restoration.
4. Verify that disclosure has one stable focus target and no duplicate label or action.
5. Exercise Dynamic Type through `2.0`, dark mode, high contrast, reduced motion, safe areas, macOS narrow windows, keyboard-only navigation, and process restart.
6. Confirm there is no Search, styled pill interaction, attachment action, picker, thumbnail, or attachment preview.
7. Capture profile traces and unresolved defects.

Expected result: Current platform mechanics work without moving product state or policy out of OCaml or adding deferred features.

#### Task 32: Run final repository gates

Files:

- Inspect `/Users/rcmerci/gh-repos/logseq_journal` and the resolved dependency mirror.

Steps:

1. Run `opam exec -- dune runtest` in `/Users/rcmerci/gh-repos/logseq_journal`.
2. Run the existing relevant OCaml and Flutter dependency suites without changing `/Users/rcmerci/gh-repos/bonsai_flutter`.
3. Run `opam exec -- bonsai-flutter sync-project --check` and `opam exec -- bonsai-flutter sync-host --check`.
4. Run `flutter analyze --no-pub` and the project Flutter host, golden, and integration suites.
5. Run `opam exec -- bonsai-flutter doctor --target=macos` and `opam exec -- bonsai-flutter doctor --target=iphoneos`.
6. Run `opam exec -- bonsai-flutter build --no-codesign macos` and `opam exec -- bonsai-flutter build --no-codesign ios`.
7. Assert that `flutter/lib/app`, `flutter/lib/core`, and `flutter/lib/features` do not exist.
8. Search project Flutter production code for `JournalTimelineController|JournalDatabase|JournalRepository|JournalEntry|CustomScrollView|SliverList|TextSpan|WidgetSpan|Image.file|sqlite3|sqflite|drift` and require zero product matches.
9. Search all product code for `Search_route|pending_search|Search_boundary|Journal_worker.Search|SearchPage|SearchController|journal_search|GraphDocumentBroker|journal.sqlite3` and inspect every match.
10. Search first-release code for `Inline_flow|Measured_extent_list|Local_image|pick_file|pick_media|attachment|expanded_semantics` and require no product implementation or dormant schema path.
11. Verify that `/Users/rcmerci/gh-repos/bonsai_flutter` has no change from this project and that the generated mirror matches the resolved dependency.
12. Run `git status --short` and verify every project change is intentional.

Expected result: All tests, generators, builds, ownership gates, reduced-scope exclusions, and device acceptance checks pass with no Dart product runtime, framework patch, or compatibility path.

## Edge cases

| Area | Required behavior |
| --- | --- |
| Ownership | A convenience request proposes Dart product behavior, a generated file drifts, the manifest is missing, or dependency source is locally modified. |
| Calendar | DST gap or fold, midnight Capture, time-zone change, locale change, future selected date, invalid stored zone, or stale platform generation. |
| Ordering | Equal sibling positions, concurrent inserts, deleted parent, orphaned child, day prepend, page append, and route return. |
| Text | Empty normalized input, huge input, NUL, invalid persistence encoding, combining marks, bidi text, emoji ZWJ, CJK, hashtags, mentions, and malformed delimiter text. |
| Editor | Stale correction, selection during update, huge paste, undo, conflict while composing, focus loss, and route disposal. |
| Known extents | Profile threshold change, wrong override index, zero viewport, narrow width, extreme scale, day prepend, expansion, collapse, and unsupported anchor behavior. |
| Disclosure | Zero children, stale count, deleted parent, partial child page, duplicate focus, duplicate label, lost focus, and untruthful Show or Hide state. |
| Timeline | No entries, one day, thousands of days, very long time label, invalid time, ellipsis, profile change at viewport edge, and final row under FAB. |
| Persistence | Database busy, crash before commit, crash after commit before response, duplicate mutation, schema mismatch, corrupt canonical store, and recovery-only startup. |
| Lifecycle | Background during Capture, foreground with changed calendar, memory pressure, process restart, route restoration, Worker shutdown, and runtime replacement. |
| Accessibility | Text scales through `3.2`, RTL, high contrast, reduced motion, screen reader, keyboard only, textual disclosure state, full source access, and no duplicate semantics. |
| Deferred scope | Screenshot contains tags and a thumbnail, source contains attachment-looking text, or a future dependency adds one missing API without an approved follow-up PRD. |
| Platform | iPhone safe-area variants, macOS narrow window, plugin failure, unsigned build, and physical-device-only backend constraints. |

## Release gates

| Gate | Pass condition |
| --- | --- |
| Ownership | OCaml owns all product UI and logic, and project Dart contains only approved host or test mechanics. |
| Framework | The release uses the resolved public dependency unchanged and has no local renderer extension or upstream patch. |
| Generator | `sync-project --check` and `sync-host --check` pass with generated files unchanged. |
| Behavior | OCaml domain, repository, Worker, Bonsai tree, route, mutation, and failure suites pass. |
| Visual | Real-runtime normalized goldens pass with Search, styled pills, and thumbnail recorded as accepted omissions. |
| Accessibility | VoiceOver, checked state, truthful textual disclosure state, full-source access, adaptive profiles, contrast, hit regions, keyboard, focus, and reduced motion pass. |
| Performance | Real-runtime profile traces meet recorded device frame, mount, window, response-size, and memory budgets using existing sparse virtualization. |
| Durability | Restart, idempotency, conflict, disk, and crash-boundary tests pass. |
| Security | Canonical-store containment, symlink, schema admission, and malformed-payload tests pass. |
| Deferred scope | Search, graph access, legacy-store handling, attachment paths, token parsers, measured-list additions, local-image additions, picker additions, and formal-expanded additions are absent. |
| iOS | Signed physical-device launch, persistence, IME, accessibility, and profile tests pass. |
| macOS | Release build, keyboard, adaptive window, persistence, accessibility, and profile tests pass. |

## Testing Details

OCaml tests exercise product behavior through public domain, repository, Worker, reducer, handler, route, and logical widget-tree boundaries.

Real temporary DataScript SQLite stores prove transactions and restart behavior instead of mocking persistence.

Existing dependency suites establish the supported sparse-list, text-input, Pressable, semantics, navigation, and host mechanics without assigning framework implementation work to this project.

Project Flutter tests start the real compiled OCaml runtime and verify geometry, current native semantics, IME, known-extent scrolling, and platform integration.

Physical-device and profile tests remain separate because debug wall time, protocol microbenchmarks, or host-only tests cannot prove release behavior.

## Implementation Details

- Keep one OCaml Bonsai product owner and one OCaml Serial Worker database owner.
- Keep project Dart limited to generated host, mechanical platform facts, and real-runtime verification.
- Use the current public `bonsai_flutter` dependency unchanged.
- Render literal block source through plain `Widget.text` and defer styled inline tokens.
- Use Compact and Adaptive known-height profiles with existing `Sparse_extent_list`.
- Use the existing plain generic text-input protocol for Capture and Detail editing.
- Persist original creation instant, local day, local minute, time-zone ID, and UTC offset in OCaml transactions.
- Keep child disclosure OCaml-owned with current truthful textual semantics and omit it if device semantics fail.
- Remove attachments, Search, preview-first UI, legacy-store handling, and pure-Dart product paths instead of adapting them.
- Require RED, verified RED, minimal GREEN, verified GREEN, refactor, and a second GREEN run for every tranche.

## Question

What exact first-release destinations and actions should appear inside Menu and More?

Tasks 25 and 26 must not invent placeholder items or implement those surfaces beyond their tested shell until that item set is confirmed.

All other first-release product, ownership, and reduced-scope decisions are confirmed.

Styled inline pills, intrinsic measured rows, attachment support, and formal expanded semantics remain future product intent that must wait for supported public `bonsai_flutter` capabilities and a separate follow-up plan.

---
