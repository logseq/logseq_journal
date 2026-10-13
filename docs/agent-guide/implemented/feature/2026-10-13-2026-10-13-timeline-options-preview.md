# 2026 10 13 Timeline Options Preview

## Problem

Timeline's menu contains application options but uses an account icon. Long row bodies expose local expansion rather than directing readers to Detail.

## Decision

Use Detail's ellipsis icon and Options accessibility label, preserving every menu action. Limit Timeline block text to four visual lines with native SwiftUI layout and remove local expansion. OCaml owns the limit; a generic bounded-text presentation in the existing native chrome adapter applies it. Detail and pagination retain their existing behavior.

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

## Risks

- SwiftUI Text retains the Timeline's current verbatim markup/link presentation. Native layout, rather than source truncation, determines visible lines.
- The native four-line limit applies independently to each displayed block body. A parent row may also retain distinct child-block summaries and image attachments. Evidence stays outside Git; dependency caches remain read-only.

## Questions

- None. The user's delegated request authorizes this scope and native presentation fallback.
