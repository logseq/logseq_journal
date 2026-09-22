# List-Owned Journal Dates with Floating Controls

## Problem

The user reports stuttering when scrolling the installed iPhone application.
The current journal date implementation displays a second date in the top
navigation toolbar, synchronized with inline dates in the native List. This
satisfied the requested top alignment but introduced application-owned work on
the scrolling path.

`swift/JournalChrome.swift` measures every journal row with `onGeometryChange`.
Each callback writes to a shared observable measurement dictionary and immediately
scans that dictionary to reconcile the active date. For N registered rows that
all move in a scroll update, reconciliation approaches O(N squared) work. The
top date and inline date headers observe the same dictionary, so unrelated row
movement can invalidate both. A local probe using the current geometry types
observed 100 invalidations of each observer for 100 unrelated row updates while
the displayed day remained unchanged. This establishes redundant work, not its
contribution to actual iPhone frame hitches; the previous acceptance suite tested
layout and interaction rather than scrolling performance.

The two date representations also require custom clipping, translation, duplicate
suppression, and lifecycle reconciliation. The desired interaction is a native
section header staying at the top until the following date pushes it away.

The preceding decision is
`docs/agent-guide/implemented/feature/2026-09-19-unified-scrolling-journal-date.md`.
This exploration replaces its Journals date/chrome ownership, not its calendar,
empty-day, pagination, navigation, or row-action requirements.

## Proposal

Remove the top navigation toolbar from the Journals timeline on iOS. Give its
space to the existing public Native_list and place the account controls in a
separate top-trailing overlay. Dates exist only as native List section headers;
SwiftUI owns their scrolling, pinning, and push-off.

The user selected this direction and requested this exploring document. iOS is
the visual and performance acceptance target; macOS needs basic usability.

### Layout and interaction

- Begin the List below the system status-area safe boundary, without an additional
  top navigation-bar band. Do not hide the status bar or use a fixed device-specific
  top offset. Retain the bottom toolbar and its actions.
- Use native section headers for Today and historical days, with date-only
  `YYYY.MM.DD` labels and a font larger than ordinary body text at normal size.
  Preserve an explicit empty Today section when appropriate. There is no duplicate
  date label outside the List.
- Place the existing Account menu in a top-trailing overlay, using a native
  Liquid Glass button presentation. Keep its actions and accessibility semantics.
  Show compact connecting feedback and the error-info control alongside it when
  required. Preserve access to sync error details without expanding a full-width
  top inset or placing long error text across the date.
- Give date headers sufficient trailing clearance for the actual control cluster,
  including accessibility sizing and error states. Keep the rest of the List full
  width. Underlying content may scroll behind the glass controls; only the controls'
  actual bounds should intercept touches.
- Align the pinned date and floating controls in the same top region. Account for
  safe areas, portrait/landscape changes and Dynamic Type without per-row scroll
  measurements. A layout measurement of the control cluster, if needed for header
  clearance, is distinct from observing every row on every scroll frame.
- Scope top navigation-bar removal to Journals. Detail retains its normal Back
  navigation, and returning to Journals preserves the existing list position.
  Favorites and other pages keep their appropriate navigation chrome.

Native List pinned-header backgrounds are an explicit feasibility gate. Verify
that real content remains visible behind the top controls and that the native
header does not introduce an opaque full-width band inconsistent with the user's
mockup. Do not assume that a clear header child removes a system-owned background.
Do not substitute a second overlay date or custom push-off implementation if the
native appearance is unsuitable; report the concrete native limitation first.

### Ownership and deletion

Keep OCaml responsible for semantic dates, formatted titles, presentation sections,
empty-day projection and mapping native row visibility to real reducer slot indices.
Keep the existing Native_list responsible for rows, actions, refresh, navigation
and token-scoped scroll requests/completions.

Replace inline historical date rows with native section headers and restore the
Today section header currently omitted by `top_section`. Headers must not invent
reducer slots or shift existing row identities and scroll targets.

Delete the obsolete Journals date machinery rather than leaving an optional path:
`DateGeometry`, `DateTitle`, `DateMarker`, per-row date wrappers, the shared frame
dictionary, toolbar date rendering and custom transition clipping. Remove native
extension modes and OCaml helpers that become unused. Retain feedback behavior
used by other pages. Any app-local native extension retained for floating chrome
must be limited to chrome/layout, with no per-frame date synchronization.

Expected implementation touchpoints are `app/journal_header.ml` and `.mli`,
`app/journal_timeline.ml`, `app/journal_native_collection.ml` and `.mli`,
`app/application.ml`, and `swift/JournalChrome.swift`, plus focused tests and
acceptance documentation. Prefer public bonsai-ui and built-in SwiftUI components.
Preserve unrelated uncommitted migration work. Do not modify Dune files, OCaml
under `spec/`, or OCaml in bonsai_flutter. If a protected interface prevents this
layout, report the precise interface issue and proposed change before development.

### Investigation and validation

Before implementation, validate the proposed native List and floating-control
layout in the isolated iPhone host. Check actual pin-line position, section-header
background, toolbar visibility scoped to the route, and control hit testing.
Engineering unknowns are not additional user approval requirements; the direction
is already authorized. Keep this document exploring until the capability findings
are recorded and the proposal is ready. While editing this exploring document,
modify no other repository file.

For performance comparison, use the same isolated fixture, Release configuration,
device, and repeatable bidirectional scrolling on the current and candidate builds.
Measure scroll hitches/frame timing with native instrumentation; do not use XCTest
wall-clock duration or a macOS dictionary microbenchmark as a frame-rate proxy.
Include ordinary scrolling within one day and transitions across date boundaries.
Report measurement limitations if device instrumentation is unavailable.

Before adding regression coverage, identify the production owner and attempt any
state defect through its public pure reducer boundary. This geometry/observation
problem is owned by native layout; the timeline reducer does not execute native
measurements or observation notifications. Test physical pinning, glass, layout
and scrolling performance at that native boundary. Keep semantic date/slot tests
at the existing public OCaml boundary and do not duplicate reducer-reproducible
regressions across higher layers.

### Capability findings (2026-09-19)

An isolated Release SwiftUI prototype ran on the paired iPhone 13 using the
existing warm-start bundle, without changing production sources or containers.
It uses the same `List` / `Section` / `.plain` primitives as the installed public
Native_list renderer. With `.scrollContentBackground(.hidden)`, clear header
children and native navigation-bar hiding, actual cyan/yellow row content remains
visible across the pinned header and behind the glass Account menu in both light
and dark appearance. There is a native translucent scroll-edge treatment, not an
opaque full-width header band. The date and account align below the status area;
the bottom toolbar remains visible. Menu activation and a row tap outside the
controls succeed. A Detail destination with explicit native navigation-bar
visibility shows Back and returns to the same row position within three points.

Evidence is retained in `/tmp/floating-native-tests/background.xcresult` and
`/tmp/floating-native-tests/light.xcresult`, with exported screenshot/AX attachments.
The prototype source is in the isolated host's `swift/App.swift` until restored;
retain a copy with the final acceptance report. XCTest passes establish these
interactions, not performance. Integrated public Native_list layout, route scoping,
large text, error controls and native frame instrumentation remain implementation
acceptance work. No protected OCaml interface has been changed.

### Integrated error-detail ownership finding

The real isolated auth token request failure exposed an integration gap: manager
`last_error` previously appeared only in the transient top sync text, while the
Error info admission checked worker errors and operation failures only. Removing
that text would make non-worker sync failures inaccessible. The native test fails
by throwing from the actual token provider, not by injecting an incorrect rendered
result. Application presentation owns this admission and details projection.
The public `Application.Root_navigation` pure reducer has no manager-state/token
completion input or sync-error state; `For_testing.app_with_service` exposes the
application runtime, not that pure ownership boundary. Consequently no public
pure reducer can execute this missing admission. Retain only the narrow existing
native auth-failure interaction check for this gap; do not add duplicated reducer,
transport or persistence tests or bypass `.mli` files. Include the manager's current
`last_error` in Error info admission and content, preserving details after transient
sync text would have expired. This requires no protected spec interface change.

## Decision

Implemented with public Native_list section headers and an app-local native
chrome/layout extension. Only control cluster size is observed. The previous
per-row date measurements, shared dictionary, toolbar date copy and custom push-off
are deleted. iPhone tests cover native pinning/reversal, transparent underlap,
Detail/Back position, Capture/actions/refresh, large text and portrait/landscape,
error details and route-scoped navigation bars. macOS basic navigation is verified.
Current non-worker sync errors are available in Error info after removal of the
transient toolbar text. Public OCaml build/tests, formatting and document checks pass.

## Alternatives considered

### Optimize the existing toolbar-date synchronization

Batching measurements and narrowing observation could reduce overhead, but would
retain two date representations and application-owned push-off behavior. The user
selected native List ownership instead. Do not keep this as a compatibility mode.

### Leave an empty leading toolbar region

Removing its title alone does not establish that List headers can pin alongside
the trailing buttons. The navigation bar can still reserve a full-width safe-area
band. Removing top chrome from the Journals route makes the intended layout clear.

### Replace Native_list with a custom scroll container

This would expand the change into row actions, navigation, refresh and positioning.
The existing native List already supports section headers. A replacement is not
justified unless a specific capability failure is demonstrated and separately
resolved.

## Acceptance criteria

- On iOS Journals, the top navigation toolbar and its reserved band are absent;
  the bottom toolbar remains. Detail/Back and other routes retain their navigation.
- Today and history dates each have one List-owned header representation. Native
  section behavior provides forward/reverse pinning and push-off without custom
  geometry-driven date animation.
- The pinned date and floating account controls occupy the intended top region,
  with no date/control overlap in normal, connecting, and error states, portrait,
  landscape, and large-text layouts.
- Controls use native Liquid Glass. Actual scrolling content underlaps them;
  the date presentation introduces no unacceptable opaque full-width top band.
  System transparency/accessibility behavior remains native.
- Initial and empty Today, Capture, midnight, hidden-day restoration and pagination
  retain correct calendar labels and section identity. Synthetic headers do not
  change reducer slot indices or row scroll targets.
- Account actions, error details, Capture, refresh, row actions and Detail/Back
  position retention work. Overlay space outside controls does not block scrolling
  or row taps. Accessibility exposes one date header per section and usable controls.
- No custom per-row date geometry tracking, shared measurement dictionary,
  toolbar date copy or legacy synchronization path remains.
- Repeatable iPhone scrolling is compared against the installed implementation,
  with native hitch/frame measurements and retained evidence where supported.
  Functional screenshots alone do not establish performance acceptance.
- Relevant public OCaml tests, native acceptance, build/format checks and
  `spec-dev-tool check --all` pass. macOS remains basically usable.

## Risks

- Native section-header backgrounds and pin-line behavior may not match the desired
  transparent top presentation. This must be established on iPhone before claiming
  the design is feasible end to end.
- Navigation-bar visibility can propagate through a navigation stack. Incorrect
  scoping could hide Detail's Back button or alter return-position behavior.
- Floating controls can cover headers, long content or touch targets, especially
  with large text and sync errors. Clearance and hit testing need native checks.
- Removing known redundant work may not eliminate every source of stutter. Native
  List rendering, content size and other runtime work still need measured comparison.

## Consequences

The same Release fixture/device/gesture sequence was measured three times per
implementation with native scroll signpost and app hitch metrics. Mean reported
FPS was 57.70 before and 57.14 after; both reported zero hitches. This does not prove
an improvement or elimination of stutter. SDK frame-count output was zero despite
nonzero FPS; an earlier all-process Instruments trace failed during processing.
These limitations, raw metrics, binary hashes and screenshots are retained in
`docs/test-reports/2026-09-19-floating-controls/README.md`.

Only the isolated test bundle was installed. Unrelated migration changes and all
protected files were preserved.

## Questions

- None requiring a new product decision. The user explicitly selected List-owned
  dates, removal of the top toolbar, independent floating controls, and creation of
  this exploring document. Remaining native-layout and performance unknowns are
  investigation tasks described above; report a demonstrated capability conflict
  before proposing a different design.
