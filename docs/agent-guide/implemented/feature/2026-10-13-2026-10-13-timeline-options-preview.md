# 2026 10 13 Timeline Options Preview

## Problem

Timeline's menu contains application options but uses an account icon. Long bodies expand inline, and empty parents can remain visible because a child contains an image.

## Decision

Use Detail's ellipsis icon and Options accessibility label, preserving every existing menu action. Limit Timeline text to four visual lines with native SwiftUI layout and remove local expansion. OCaml owns policy; a generic bounded-text mode in the existing chrome adapter applies native wrapping. Retain at most three child summaries in sibling order, including image/file summaries. Each text summary also has four lines.

After viewing the actual screenshots, the user replaced the empty-preview policy: a Timeline parent appears only when its own text, tags or attachment metadata is present. Child content and child count do not qualify it. Remove the Open block placeholder. Task status is a separate property: status alone does not qualify a parent, while a real Task tag qualifies as a tag. Reuse existing root file type, typed asset references and tag membership/titles; do not request another attachment scan or broaden reads. Generic metadata presence travels through the app's OCaml model so Feed and canonical point updates make the same decision. Only the ordinary app model interface is extended; protected spec interfaces are unchanged.

Detail and Copy remain complete. Canonical mutation completion still returns an invisible root with its true child count. Timeline state filters empty cards in complete and partial days, handles clearing an existing parent, and restores a newly qualifying parent in an already known day without depending on its child count or status. Day continuation and stable navigation identities retain their existing ownership.

## Alternatives considered

### Character or newline truncation

Rejected because visual lines depend on width, language and Dynamic Type. The installed LUI text node exposes a three-line style, so native bounded text is required without changing the dependency.

### Empty preview placeholder

Replaced by the user's explicit parent-only visibility policy. Child images, later summaries and status alone no longer retain an otherwise empty Timeline parent.

## Consequences

- Runtime RED reproduces empty child-image parents and status-only parents surviving in Feed and mutation confirmation. The same public owner covers Feed, day continuation, remote reconciliation, legacy refresh and Capture/Update/Status confirmation with text, tags, PNG, PDF and typed attachment-reference cases.
- Public Timeline state regression covers multiple empty siblings, canonical clearing/restoration, tag/image/file-only parents and status-only point updates. Existing empty-day expectations now match parent-only visibility; no row-level duplicate behavior regression replaces these pure owners.
- The old Open block mounted regression and child-image-only empty-parent gallery regression are removed because their policies are obsolete. Other rendering, media lease, menu, source, Dynamic Type and Detail tests remain.
- Existing public Detail/Copy regression now begins with a hidden empty parent and 199 children, including an image child. Complete child order and the final source remain available through unchanged read limits and Copy traversal.
- Status-setting operations only write the status property and timestamps; they do not automatically add a tag. The visibility condition deliberately has three qualifying facts.
- Earlier screenshots at 097ac2e2 retain historical evidence for the replaced placeholder. Final parent-only Simulator screenshots are recorded separately outside Git; they must not be confused with the old Open block image.
- Evidence, generated hosts and screenshots stay outside Git. Reuse unchanged LUI modules/objects read-only, compile current OCaml inputs, and keep synthetic fixture keys in memory. No Dune, protected spec, dependency, personal graph, phone or AppIcon change. Merge is not authorized.
- Decision validation retains the same three historical invalid documents as the fixed main baseline; this decision validates independently.

## Risks

- Timeline still presents markup and links verbatim. SwiftUI determines visual lines from width and Dynamic Type.
- Root attachment eligibility uses metadata already supplied by its reader. Metadata for a child's image alone is insufficient to retain the parent. No extra discovery read is introduced.
- Only row construction is bounded by the three-summary prefix. Raw projection still traverses and sorts complete members.

## Questions

- None. The user explicitly requested parent-only text, tags and attachment eligibility and removal of the placeholder.
