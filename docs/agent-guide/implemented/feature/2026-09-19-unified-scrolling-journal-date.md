# Unified Scrolling Journal Date

## Problem

The latest user mockup supersedes the earlier list-boundary interpretation.
The date belongs at the top of the application, on the same horizontal line as
the account button. It is larger than ordinary list content. It must not sit
below an opaque toolbar or occupy a second header band. Journal content scrolls
behind both controls, using the native Liquid Glass presentation. Scrolling
between journal days must still displace the outgoing date with the incoming
date, in either direction.

The first implementation placed all dates in Plain Native_list section headers
below the retained toolbar and sync feedback. Its native tests passed that
layout, but that layout does not satisfy the latest mockup.

## Proposal

Use one native date/chrome layout owner for the top date region and account
control. Retain the existing Native_list's identity, navigation, actions,
visibility projection, refresh and tokenized positioning. Keep date formatting
and semantic section identity in OCaml. Keep measured section positions,
clipping and per-frame translation native.

The native presentation must:

- Align the active date and account control in the top safe-area control row.
- Use a date font larger than list body text, with the mockup's date-only title.
- Allow actual list content to scroll behind the controls; remove the opaque
  full-width date background and do not simulate glass with reduced opacity.
- Move outgoing/incoming date content using measured section boundaries and a
  common top coordinate space, while suppressing duplicate pinned headings.
- Keep account/navigation/Capture actions accessible and preserve sync feedback
  without pushing the date into a lower, separate band.
- Respect system accessibility settings, including Reduce Transparency.

### Current capability boundary

`bonsai-ui/ocaml/ui/view.mli` exposes Native_list section header views, visible
row ranges, and explicit row-positioning commands/completions. It exposes neither
section-header geometry nor a pin-line/chrome policy. Toolbar exposes native
placements but no connection to list-section geometry. A first-visible-row title
switch cannot reproduce the requested continuous push-off with variable-height
rows. Moving the current heading to Toolbar alone is insufficient.

The installed native implementation is in
`bonsai-ui/swift/BonsaiSwiftUI/Sources/NativeList.swift`; it delegates section
headers to SwiftUI List. The application cannot assume a clear child background
removes the native pinned section's background. The existing JournalChrome
extension owns sync-feedback safe-area reservation only.

A physical iPhone SwiftUI prototype has now confirmed top alignment and native
content underlap. The date and account control share the top toolbar line; actual
colored list content remains visible through the system scroll-edge effect and
account control. The top date uses title2 text and a hidden shared toolbar
background. No SDK change was needed for this experiment.

The application integration uses a small native extension for the remaining
geometry connection. Public Native_list still owns rows, actions, navigation,
visibility, refresh and positioning. Inline dates are ordinary presentation rows
rather than separately pinned native section headers. Native markers measure
actual row/date positions with SwiftUI onGeometryChange. One graph-scoped native
owner supplies the top toolbar date, clipping and translating the outgoing and
incoming labels. No per-frame geometry crosses into OCaml; OCaml supplies date
identity and formatted titles. Existing feedback safe-area reservation remains
for other pages; Journals moves sync feedback into its retained toolbar.

Physical iPhone acceptance covers first-Today spacing, sync-feedback width,
reverse scrolling, recycling and the transition between inline and toolbar date
text. Final verification uses the exact integrated native build. No protected spec, Dune file or
bonsai-ui implementation change is involved.

## Decision

Use the public Native_list with inline historical date markers and an
application-local native top-toolbar geometry owner. OCaml owns semantic dates
and row projection; SwiftUI owns measurements, clipping, translation and native
Liquid Glass. Omit the duplicate inline Today heading. Keep existing reducer,
action, navigation and scroll-completion ownership. Prioritize iOS visual
correctness and retain basic macOS usability as requested.

## Alternatives considered

### Other presentation approaches

- List-owned date below the toolbar: implemented and tested as the earlier
  interpretation, now superseded by the user's annotated mockup.
- Toolbar text from first visible row: only switches a label and cannot represent
  section push-off progress; not sufficient.
- Replacing Native_list with Scroll_sections: loses the current list visibility,
  positioning, row-action and navigation contracts; not justified by this layout.
- A translucent full-width date bar: still obscures the underlying list as a
  separate band and does not match native Liquid Glass controls.

## Acceptance criteria

- The date is at the top safe-area control row, aligned with the account button,
  and visibly larger than the body text.
- Real list content continues behind that region. The date and account control
  use native glass behavior without an opaque full-width header beneath them.
- Incoming dates physically displace outgoing dates at that top location in both
  directions, with exactly one active date region and no duplicate pinned title.
- Initial/empty Today, Capture, midnight, hidden days and pagination remain correct.
- Fast scrolling, long rows, reversal, large text, rotation, safe areas, sync
  feedback and light/dark appearance have no text/control overlap.
- Detail/Back retains position. Row actions, refresh and positioning completion
  retain their existing production owners and semantics.
- Verify the new top geometry and compositing on iPhone; previous below-toolbar
  screenshots are not acceptance evidence for this revised layout. Per the user,
  iOS is the visual acceptance target; macOS only needs basic usability. Test state changes at their public pure owner; test physical
  compositing only at the native boundary.

## Risks

- Geometry is application-owned and uses public SwiftUI measurements. Native
  toolbar layout changes require physical device verification. The prototype and
  integrated tests established the common coordinate space.
- Existing public bonsai-ui migration work is uncommitted and must be preserved.
- Do not modify protected spec OCaml, Dune files, or bonsai_flutter OCaml files.
  Report any required protected-interface change before implementation.

## Implementation status

The earlier below-toolbar implementation and its native evidence are superseded.
The top-toolbar SwiftUI prototype passed its device alignment assertion and
provided screenshots showing actual list content behind the top controls.
Source, XCTest and screenshots are retained under
`docs/test-reports/2026-09-19-unified-scrolling-journal-date/top-toolbar-prototype/`.
That experiment was a disposable native layout and does not prove application
integration or complete push-off behavior.

The application now supplies native date markers and a graph-scoped top toolbar
owner. New public-view assertions failed before implementation and pass after
it; the OCaml test suite also passes. The integrated iPhone suite has passed top alignment, continuous push-off,
reverse and fast scrolling, rotation, large dark text, Detail/Back, row actions,
Capture and refresh. The exact-source final native checks passed: large-text and actions passed in
the final suite; the date case passed in an isolated retry after a system Home
screen interruption. Evidence and artifact hashes are retained in
`docs/test-reports/2026-09-19-unified-scrolling-journal-date/README.md`.
macOS date scrolling, Account, Journals, Favorites, Capture and Detail/Back were
checked for basic usability. Separate toolbar items avoid hidden macOS group
controls while preserving iOS grouping.

## Consequences

The date shares the top control row and list content underlaps native chrome.
Date transitions require no per-frame OCaml traffic or SDK changes. Native
geometry must be verified on iPhone when toolbar or typography changes. Other
pages retain the existing feedback inset. The earlier below-toolbar report is
retained as historical evidence and is not acceptance for the revised layout.

## Questions

- None. The latest mockup defines the target, and the native prototype established
  a path using the existing SDK and an application-local geometry extension.
