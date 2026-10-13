# 2026 10 13 Timeline Options Preview

## Problem

Timeline's menu contains application options but uses an account icon. Long row bodies expose local expansion rather than directing readers to Detail.

## Decision

Use Detail's ellipsis icon and Options accessibility label, preserving every menu action. Limit Timeline block text to four visual lines with native SwiftUI layout and remove local expansion. OCaml owns the limit; a generic bounded-text presentation in the existing native chrome adapter applies it. Detail and pagination retain their existing behavior. After the user clarified that the whole card may exceed four lines but must remain bounded, Timeline projections and the public row renderer retain only the first three child summaries in sibling order, including image/file summaries. Each text body still has four visual lines; the root plus three text summaries can occupy at most sixteen body lines. Raw members, true child count, Detail and Copy remain complete; no read strategy changes.

A retained parent can have empty root text and three empty summaries while a later image keeps the entry valid. If the selected preview has no text, status, tags or known attachment, render the short “Open block” label under the same four-line policy. The existing whole-row navigation opens Detail. Resolve selected text only once and inspect only the three-summary prefix; do not search later children, remove the entry or add expansion.

## Alternatives considered

### Character or newline truncation

Rejected because visual lines depend on width, language and Dynamic Type. The installed LUI text node only implements a three-line style, so a native bounded-text presentation is needed without modifying the dependency.

## Consequences

- Mounted production tests cover short and long English, Chinese, newlines, long words, markup, links and resolved references with the same four-line policy and intact source.
- No row Show more/Show less action remains; the existing row navigation opens complete Detail. Menu actions remain clickable.
- Actual iPhone 13 / iOS 26.1 screenshots show exactly four visual lines for English, Chinese, long words and verbatim Markdown/links; short text stays one line. Accessibility XXXL still shows four visual lines. Image attachments keep their native layout. Root body and each distinct child-block summary use the same limit; media discovery ownership is preserved.
- Mounted RED fails for the old expansion and Account menu. Full build/native embed and all 21 Alcotest suites pass (730 cases, including 224 sync and 79 application cases), plus standalone semantic/adaptive/source boundary checks. All five menu callbacks retain their original actions; actual native Options opens Diagnostics and body taps open complete Detail.
- Test hosts and screenshots stay in the task's external evidence directory. An independent host links the current production OCaml object restamped using the existing simulator build convention; only unchanged LUI modules/objects are read from the released cache. No dependency, Dune, protected spec/mli, phone, real graph or AppIcon change.
- Repository-wide decision validation has the same three historical invalid documents as fixed main; this decision validates independently. The user subsequently authorized a separate non-draft PR and CI tracking; merge is not authorized.

- Independent review found eleven existing Timeline/Favorites UI acceptance selectors still using Account menu. The two native-list acceptance sources now query Options, and the warm-start instructions use the same name. A narrow RED/GREEN comparison against saved actual native accessibility output verifies all eleven selectors; Swift parsing verifies both sources. No product change, full rebuild, Simulator rerun or phone operation was needed for this correction. Startup-specific Account menu labels remain valid.

- The summary-count RED cases reproduced 199 summaries in Feed and 10,050 summaries after paginated Capture/Update/Status completions. Public Runtime GREEN covers Feed, day continuation, remote page-tree reconciliation, legacy refresh and mutation confirmation through the shared projection. The five new cases retain true counts and all 199 Detail/Copy children; the full 106 Runtime and 79 Application cases, 47 semantic cases and Timeline state regressions pass.
- The public renderer invokes source/media callbacks only for the root and first three summaries. Measured allocation is 7,360 bytes for 3, 201 and 10,050 input summaries. This presentation follow-up changes only two OCaml implementation files and tests; no new Swift/native host build or Simulator/device run was needed. Earlier native screenshots establish the unchanged four-line typography, not the new summary-count cap.
- Incremental review reproduced an unidentifiable historical row using public Runtime Feed completions and Timeline state: the first three child sources are empty and the fourth is an image. These owners preserve valid data but do not own visible labels, so a single mounted renderer regression covers the label and existing navigation, with guards for visible root/child text, status, tags and selected root/child images. RED fails on the missing label; GREEN retains the four-child count, three-summary prefix and block identity without visiting the fourth source. Row construction now allocates 7,536 bytes for each of 3, 201 and 10,050 input summaries. This measurement applies only to row construction; raw projection still traverses and sorts complete members. No GUI evidence was produced for this boundary.

## Risks

- SwiftUI Text retains the Timeline's current verbatim markup/link presentation. Native layout, rather than source truncation, determines visible lines.
- Child summaries count toward a three-item preview budget regardless of media type. Later children and attachments remain in Detail. The renderer takes the prefix before partitioning, resolving sources or constructing media views, so work does not grow with hidden summary count. Evidence stays outside Git; dependency caches remain read-only.

## Questions

- None. The user clarified the aggregate card may exceed four lines while remaining bounded, and the parent explicitly authorized the three-summary display cap.
