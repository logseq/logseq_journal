# Replace All Supported UI with Public bonsai-ui Components

## Problem

The application still implements standard SwiftUI components through six custom
native registrations: JournalList (2101), JournalForms (2102), JournalChrome
(2103), JournalConfirmation (2104), JournalOutline (2105), and JournalFavorites
(2106). These registrations duplicate structural UI, event admission, visibility,
scrolling, navigation, and presentation behavior now supported by bonsai-ui.

The audit baseline is the local bonsai-ui source at `0f4f343` (2026-09-18).
The consumer's `logseq_journal.opam` still pins the
`2026-09-16-cooperative-shutdown-final` archive. That archive uses protocol 8;
the audited framework uses protocol 10. Package version strings alone do not
establish that the installed host and iOS artifacts contain the new APIs.

The user requested an exploring decision covering replacement of every UI
component that bonsai-ui can support. This document records that complete scope;
it does not authorize leaving supported bridges in place for convenience. The
implementation record below describes the completed consumer cutover.

## Decision

Implement the public-component cutover described above, with the user's removal
of reading density and final macOS-only verification instruction. The consumer
has one active renderer, matching protocol-10 dependencies, and no compatibility
transport. Retain only registration 2103's unsupported layout/material fragment
and the explicitly documented pre-runtime/authentication host boundaries.


Adopt the public bonsai-ui UI surface throughout the current OCaml/SwiftUI app.
Replace every supported standard component, including components expressible by
composition of public APIs. Delete superseded Swift registrations, OCaml native
widget encoders/decoders, polling, payloads, and registration calls after their
last consumer is removed. Do not add compatibility layers, fallback renderers,
legacy protocol decoding, feature flags, or migrations.

Preserve application behavior and state ownership. OCaml continues to own graph
selection and startup, routes, pagination, expansion, drafts, editor revisions,
mutation acceptance, synchronization, and confirmation decisions. The framework
owns native presentation, layout, input admission, and lifecycle fencing.

The user confirmed on 2026-09-18 that system presentation differences are
acceptable; the result does not have to look exactly the same. Prefer native
spacing, grouping, typography, and toolbar arrangement over recreating the old
appearance. Preserve functional behavior, accessibility, native Dynamic Type,
and `docs/ux-guidelines.md`. Cosmetic differences alone are not capability gaps
and must not justify retaining a custom bridge or adding framework features.

### Complete replacement inventory

| Current component and location | Public replacement | Required application behavior |
| --- | --- | --- |
| `Native_form.form` in `app/application.ml`; `JournalForms.swift` form case | `View.Form.vertical` | Settings, status selection, diagnostics, and error details remain usable and scrollable. |
| `Native_form.section`; native Section wrappers | `View.Section.create` | Preserve section titles, content, and stable row identities. |
| `Native_form.labeled`; diagnostic and error metadata | `View.labeled_content` | Keep values noneditable and selectable. |
| `Native_form.unavailable`; Journal empty overlay | `View.content_unavailable` | Preserve every empty/error message, symbol, enabled action, and recovery command, including Favorites and unavailable Graph/Block states. |
| Descendant `.textSelection(.enabled)` in supported wrappers | `View.text_selection` | Preserve native text selection without introducing editing. |
| `Native_form.list` for Graph selection | `View.Native_list.vertical` | Use the platform-appropriate native list style and retain graph selection commands. |
| `swift/JournalList.swift`, `app/journal_native_collection.ml`, `app/journal_timeline.ml` | `Native_list.section`, `row`, `vertical` | Preserve date groups, loaded entries, loading/empty states, pagination, and return-from-detail position. |
| `swift/JournalFavorites.swift`, `Native_favorites` in `app/application.ml` | `Native_list.vertical` and `on_visible_range` | Preserve favorite identities, loading/error/retry states, and pagination. |
| Journal/Favorites full-row open buttons and pending-open machinery | `View.Navigation_link.create` | Keep route acceptance in OCaml; provide stable keys, semantic activation identities, and handler bindings. |
| `swift/JournalOutline.swift`, `Native_outline` in `app/application.ml` | `Native_list.disclosure_row` and ordinary rows | Preserve expansion, independent parent/child actions, child loading, editing, and append behavior. |
| Journal status/delete and outline delete swipes | Row-owned `View.Swipe_actions` descriptors | Preserve labels, roles, enabled state, direction, and disabled full-swipe behavior. |
| Journal and outline context menus | `View.Context_menu` row slots or `attach` | Preserve commands and reject actions belonging to removed/replaced owners. |
| Journal positioning and outline reveal after append | `Native_list.target`, `scroll_request`, `completion_of_payload` | Use monotonic tokens, scoped row paths, explicit anchors, and terminal outcomes. |
| `swift/JournalListViewport.swift` and custom visibility timers | `Native_list.vertical ~on_visible_range` plus application projection | Preserve correct paging observations without native polling or estimated row heights. |
| Toolbar portion of `swift/JournalChrome.swift` and `app/journal_header.ml` | `Toolbar.item`, `group`, `child`, `spacer`, `Bottom_bar` | Preserve Journals/Favorites navigation, selected state, Account, error entry, Capture, and system Back. |
| `swift/JournalConfirmation.swift`, `Native_confirmation` in `app/application.ml` | `View.Confirmation.alert` | Preserve destructive/cancel semantics and emit one accepted response per request token. |

This inventory is a minimum, not a whitelist. Before implementation, inspect all
active UI constructors and host views for additional supported portions. Record
each replacement or a concrete public-API capability gap. Do not count an API as
supported solely because its name resembles the existing component.

### Composite layouts and retained platform responsibilities

Audit `JournalForms` reading, feedback, and unlock cases, `JournalUnlockView`, and
`JournalChrome` title/subtitle and sync-feedback layout at the level of individual
parts. Replace supported text, symbols, controls, selection, layout, and progress
portions with public composition wherever behavior can be preserved. A lack of a
single matching constructor is not grounds for retaining an entire custom view.

Reading density was explicitly removed by the user on 2026-09-18 instead of
retaining unsupported Dynamic Type curves. Remaining gaps concern responsive
feedback placement and safe-area behavior. Existing unlock decorations
may be simplified to native presentation; visual fidelity alone is not a gap.
Any retained custom fragment must identify the missing API and required behavior,
contain only that fragment, and leave no duplicate implementation of a supported
standard component. If all fragments become expressible, remove the registration
entirely. Do not assert that all six registrations must disappear before this
audit establishes that all their behavior is supported.

Also audit `swift/App.swift` and `JournalAuthenticationView.swift`. The host App,
runtime bootstrap, platform services, and Amplify authentication ownership are
not generic UI components. Replace supported presentation portions where the
public runtime boundary permits it; do not move authentication or bootstrap state
merely to eliminate native source files. Document any pre-runtime or host-owned
presentation boundary that prevents replacement.

Existing public components such as Button, Menu, Picker, Sheet, Navigation_stack,
text/secure fields, and text editors should remain public components. Adopt new
options only when they serve an existing behavior: editor autofocus is already
used. Progress supports `Automatic`, but existing determinate Linear and
indeterminate Circular combinations do not need gratuitous changes.

### Integration constraints

- Resolve one matching framework source/archive, host packages, tool, and iOS SDK
  set. Record exact source identity and protocol/ABI metadata. Do not infer SDK
  availability from the source commit or use mismatched installed artifacts.
- Keep iOS/macOS 26 minimums. `Inset_grouped` and `Bottom_bar` must never be emitted
  for macOS; select supported native platform presentations explicitly.
- Supply stable sibling keys for forms, sections, rows, toolbar entries/children,
  and actions. Use typed vertical Body slots for Form/List viewports instead of
  wrapping them as static views or nesting unbounded scrolling containers.
- Map row-only visible indices to the application's timeline slots. Framework
  indices exclude section headers/footers and collapsed descendants. Current
  Journal observations include header slots; forwarding indices unchanged is
  incorrect. Loading and empty-day rows need an explicit mapping as well.
- Scroll targets are rows, not section headers. Resolve existing date/top intents
  to the appropriate row or identify a genuine unsupported header-alignment
  requirement. Process completion outcomes; visibility alone is not success.
- Preserve the same List owner when returning from detail. Do not issue a new
  scroll command on every render or reconstruct the list to restore position.
- Preserve loaded descendant data and application expansion authority. Parent
  label activation, expansion, swipe, and context actions must stay independent.
- Replace confirmation Boolean transport with token-scoped action/dismissal
  events. Preserve the stable base child and existing cache-reset reducer effects.
- Follow `docs/ux-guidelines.md`: at most three dividers, immediate reopening of
  the most recently opened graph, and preference for appropriate built-in UI.
- Do not modify Dune files, OCaml under `spec/`, or any bonsai_flutter OCaml file.
  If a protected spec blocks the work, stop and report the exact issue, suggested
  interface change, and rationale. This proposal does not grant that permission.

### Implementation and verification sequence

1. Verify dependency availability and finish the supported/gap inventory against
   the exact installed public interfaces, applying the accepted native presentation
   policy above.
2. Integrate matching dependencies, then replace forms, sections, labeled values,
   unavailable views, text selection, and Graph selection presentation.
3. Replace Journal/Favorites lists, navigation links, row actions, visibility
   projection, and scrolling; then replace hierarchical outline presentation.
4. Replace standard toolbar and confirmation ownership. Complete the composite
   layout audit and remove all superseded registrations and support code.
5. Update affected tests to exercise public components and application behavior.
   Validate macOS and iOS integration and record remaining capability gaps.

For any bug found during migration, identify the production state owner first
and attempt reproduction through its public pure reducer events, completions,
state, and effects. If that reproduces the bug, add only reducer regression tests.
Otherwise document the missing boundary and test the narrowest layer executing
the defect. Do not inject an already incorrect external result as a purported
pure reproduction, bypass `.mli`, copy implementation logic, or move production
ownership to change test classification. Preserve existing tests; do not delete
coverage merely because a custom bridge disappears. Update representation-bound
assertions to verify the replacement's observable behavior.

Use focused application checks for index mapping, scroll/confirmation token
handling, and route/expansion ownership. Use native integration checks for actual
List geometry, gestures, selection, toolbar placement, and editor retention;
do not duplicate framework-internal test suites in the consumer. Final evidence
must include appropriate builds and tests for the affected application, real
platform interactions, `git diff --check`, and `spec-dev-tool check --all`.

## Alternatives considered

### Keep all custom native registrations after upgrading the dependency

This leaves duplicate owners for behavior supplied by the framework and does not
fulfill the requested complete replacement.

### Replace only forms and other low-risk containers

Useful as an implementation sequence, but not an acceptable final scope. Lists,
row actions, navigation, toolbar groups, and confirmations are also supported.

### Delete every Swift UI file regardless of capability

This can remove required application behavior or force authentication/bootstrap
ownership into an inappropriate runtime boundary. Replace every supported part;
retain only specifically demonstrated gaps and necessary host responsibilities.

### Maintain old and new renderers behind a switch

Rejected by repository policy. The dependency and consumer cutover has one active
implementation and no compatibility path.

## Acceptance criteria

- Native presentation differences are accepted without pixel-for-pixel matching;
  cosmetic differences do not retain custom implementations. Functional behavior,
  accessibility, native Dynamic Type, and UX guidelines remain satisfied.
- Every inventory row uses the public bonsai-ui API, with no supported standard
  UI still implemented through an application native registration.
- A final audit accounts for every remaining custom UI fragment and host view,
  naming its public-API gap or required host boundary. Supported subparts are
  replaced even where a larger composite retains an unsupported fragment.
- Superseded registration IDs, JSON codecs, polling, pending-open state, viewport
  helpers, and registration calls have no active remnants or compatibility paths.
- Forms, diagnostics, Graph selection, empty/error states, Journal, Favorites,
  outlines, toolbar actions, and destructive confirmation remain functional on
  iOS and macOS with the correct native styles and separator budget.
- Timeline pagination is correct around date headers, empty days, and loading
  rows. Expanded outline indices and row action ownership remain correct.
- Opening a row, interactive/system Back, returning to the prior list position,
  append-and-reveal, repeated scroll targets, and cancellation work without lost
  actions, unintended expansion, duplicate effects, or forced scroll resets.
- Confirmation cancel, outside dismissal where applicable, destructive action,
  and reopening have correct token ownership and preserve cache-reset semantics.
- Existing secure input and editor revisions, drafts, focus, selection, and IME
  composition survive relevant presentation changes; stale callbacks cannot act
  on replacement owners. Native Dynamic Type and Reduce Motion remain effective.
- Cold/warm startup still opens the latest graph directly. Graph selection,
  encryption unlock, authentication, synchronization, and recovery remain usable.
- The dependency source and generated artifacts match. Consumer build/test and
  native interaction results are recorded separately from framework evidence;
  compilation or accessibility snapshots alone are not interaction acceptance.
- Known upstream failures are reported with their consumer impact, not relabeled
  as passes. No protected source or Dune file changes are required or performed.

## Risks

- The protocol cutover makes a mixed dependency installation unusable. Local
  source support does not prove that a matching distributable SDK is installed.
- Row visibility semantics differ from the custom adapters; wrong projection can
  skip data, repeat loads, or stall pagination despite correct native rendering.
- Recreating List, link, toolbar, or editor owners can lose scroll position,
  pending intent, focus, selection, or composition.
- Native Form and toolbar presentation can differ from the custom wrappers.
  These differences are accepted; verify usability and the separator budget
  rather than reproducing the previous spacing or decoration.
- Upstream's 2026-09-18 evidence reports passing new public-API device tests, but
  its aggregate suite is not wholly green; baseline Menu completion, Sidebar modal
  reopening, and AppBars resize failures require consumer relevance assessment.
- Public confirmation actions may expose different accessibility identities;
  preserve user-facing semantics and adapt tests through supported interfaces.

## Consequences

Standard native UI lifecycle and event admission now belong to bonsai-ui;
application graph, route, draft, expansion, confirmation and scroll-token state
remain in OCaml. The removed preference is no longer configurable. Native Form
and toolbar presentation may differ from the prior custom views.

The known macOS top-inset completion mismatch is reported as an upstream
limitation rather than hidden by a consumer workaround. Visible Capture
positioning works, but terminal success is not claimed for that geometry.
Final iPhone validation remains unavailable under the user's macOS-only testing
instruction; earlier failures and the exact tested revisions are preserved in
the evidence report. These limitations do not retain obsolete UI paths.

## Implementation record

### Dependency preflight (2026-09-18)

- Source baseline: `0f4f34311254d7968c2b04daf9fcb2b43e525a65`.
- Local release: `/Users/rcmerci/.local/share/bonsai-swiftui/releases/2026-09-18-journal-native-210435/final/bonsai-swiftui-0.1.0~dev.tar.gz`.
- Installed host switch: `bonsai-ui`; tool and UI public interfaces include Form,
  Native_list, Navigation_link, Confirmation, and Toolbar groups.
- Installed iOS framework SDK: `0.1.0~dev.45`; runtime SDK: `0.1.0~dev.8`;
  ABI 4; source archive SHA-256
  `03b0086348a81229060525c3e4b82bc9ac0d0776aac9c06a8530be40871abc36`.
- All four consumer opam manifests now select the same final release archive.
  Final archive SHA-256:
  `e2afa48c984833edbff34ccb7523b1d50372695fb65e8ef8f88c36e88e65766e`.
- The installed framework source was compared against that archive: all 474
  OCaml interfaces/implementations, Swift files and protocol schemas match.
  Existing global opam pin pointers were not changed; byte comparison and the
  installed SDK verification establish the actual build inputs independently
  of those mutable pointers.
- `bonsai-swiftui toolchain verify iphoneos` passed with fingerprint
  `5f03e654d7d3f52164e4dc059f3883d04b10d8904a9abf428e19a87370c92c8a`.
- Baseline `dune build @all` fails because the application dispatch match does
  not yet handle the new `Confirmation_response` event variant.

### Composite audit

- Reading density: removed at the user's explicit request on 2026-09-18. Use
  native framework typography. Remove the setting, preference wire protocol,
  startup preference gate, and inherited native font wrapper; do not retain a
  bridge for unsupported reading-density curves.
- Unlock: all functional pieces can use public Text, Symbol, secure field,
  Button, Section, and Form. Native decoration is not required.
- Operation feedback: public label, text, actions, and layout are supported.
  Native safeAreaInset and ViewThatFits are not public; retain only those layout
  responsibilities if needed, with supported content supplied as child views.
- Chrome: toolbar entries, groups, title/subtitle content and progress are public.
  Safe-area feedback placement remains the minimal host layout fragment.
- App and authentication: runtime initialization and Amplify session ownership
  occur outside the OCaml runtime and remain host responsibilities.
- Form separator control: public Form/Section currently have no separator option;
  group diagnostic metadata into content rows to respect the divider budget.

### Work sequence

1. Complete dependency identity checks and replace structural forms/unavailable
   content; verify failing public-component assertions before implementation.
2. Replace lists, route activation, row actions, visibility projection, scrolling,
   and outline disclosure; test public application ownership boundaries.
3. Replace toolbar and confirmation; remove obsolete registrations and payloads.
4. Run focused tests, full builds, platform interactions, formatting and decision
   document checks; record evidence and remaining gaps.

### Final component and host inventory

- Form, Section, LabeledContent, ContentUnavailable, descendant text selection,
  Graph selection, Journal, Favorites and outline rows use public views. Native
  Form metadata is grouped into one column per section to avoid excess dividers.
- Journal/Favorites activation uses Navigation_link. Disclosure, row-owned swipe
  actions and context actions are public components with stable semantic keys.
  Row visibility is projected past date headings, including explicit empty-day
  rows and continuation rows. An empty Journal overlays ContentUnavailable while
  retaining its List owner.
- Journal scroll requests freeze the first available row after Capture (the
  existing return-to-top behavior); outline requests freeze the appended child
  path. Completion tokens are scoped to graph/detail owners and all terminal
  outcomes are recorded. Visibility does not complete a request.
- Toolbar items, groups, children, title/subtitle and feedback content are public.
  iOS uses Bottom_bar; macOS uses Navigation/Primary_action. Graph selection uses
  Inset on both platforms. No macOS Inset_grouped or Bottom_bar is emitted.
- Cache reset uses public Confirmation with a monotonically increasing token,
  explicit cancel/destructive roles and one accepted reducer effect. Old Boolean
  confirmation transport has been removed.
- Removed registrations 2101, 2102, 2104, 2105 and 2106, their registration calls,
  payload codecs, viewport accumulator/polling, custom unlock view, native Forms,
  native list implementations and old confirmation presenter.
- Registration 2103 now contains only bounded geometry, safeAreaInset,
  ViewThatFits and system bar material for feedback. Public Body slots require
  finite sizes; the public UI has no intrinsic safe-area reservation, responsive
  fitting choice or semantic system bar material API. All three child views,
  labels, progress, actions and alternative layouts are built in OCaml. The bar
  material prevents scrolled text showing through feedback. This registration
  owns no route, expansion, draft, selection, scroll or action state.
- `JournalApplication` retains App/Window/scene/bootstrap and cooperative shutdown.
  Its pre-runtime loading/storage-retry views cannot be rendered by a runtime
  whose payload or local storage failed to initialize. The authentication banner,
  Sheet, NavigationStack and `JournalAuthenticationView` remain attached to the
  Swift-owned Amplify authentication lifecycle, including challenge types,
  cancellation, secure-content hints and focus. The public OCaml rendering
  boundary does not take Swift-owned view models; replacing these would move
  authentication ownership, explicitly outside this decision. The same banner
  works before a runtime exists and while a locally restored graph is usable.
- Existing public Sheet, Menu, Picker, fields and editors remain public. Reading
  density, its Settings page, UserDefaults preference wire messages, startup
  preference wait and inherited native font wrapper are removed without migration.

### Regression ownership and verification

An unchanged public visibility observation leaves the pure Timeline state and
next request equal. The application previously scheduled a no-op model update
anyway, recreating native row bindings on every redelivery. This invalidated
open context menus and could drop row activation. The application dispatch
regression now verifies stable mounted bindings on repeated observations; no
worker, persistence or framework test duplicates it. Ignoring unchanged
observations fixes the native menu without retaining custom input buffering.

Capture return-to-top is owned by `Journal_timeline_state`. A public reducer
regression with existing rows and a chronologically later insertion failed when
the request targeted the inserted record; it now requires the first Journal row.
A second pure regression verifies that a same-graph feed reset preserves the
pending target until its terminal completion. Graph replacement still creates a
new owner. The native acceptance exercises actual positioning separately from
that reducer contract.

Completion handler bindings are stable across viewport updates and disclosure
changes, and are invalidated by graph/detail generation changes. The dispatch
regressions exercise those public mounted bindings; pure state cannot reproduce
a renderer binding replacement. The consumer no longer string-encodes completion
payloads.

Final verification follows the user's instruction to use macOS after they took
the iPhone away. Earlier device evidence remains recorded, including failures;
no final device pass is claimed. macOS build, reducer/application/runtime suites,
and real native interaction checks passed. A remaining upstream completion
limitation is recorded separately: with the native top safe-area inset, the list
visually reaches the top but reports Positioning_failed because its macOS probe
compares viewport y=-48 with minimumOffset=0. The consumer records the actual
terminal outcome, clears the request, and supports subsequent tokens; it does
not reinterpret visibility as success or add a native compatibility path.

Build commands, native interactions, failed attempts, hashes and final results
are recorded in `docs/test-reports/2026-09-18-public-bonsai-ui/README.md`.
No repository Dune file, protected `spec/` OCaml interface/implementation, or
bonsai_flutter OCaml source was changed.
