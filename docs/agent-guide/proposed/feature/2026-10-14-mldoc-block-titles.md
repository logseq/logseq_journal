# Parse block titles with mldoc

## Problem

Timeline and Detail expose markup and raw URLs; string reference expansion misreads code and escapes and loses nested styling.

## Proposal

Use official native mldoc AST in Journal_model to emit bounded styled text runs with explicit URL/block targets. Cache parsed titles with 512-entry/2MiB source-byte limits; admit at most 32 delimiter depth and 4096 open delimiters before mldoc parsing, then cap semantic conversion at 512 nodes. Reuse graph-session reference hydration, missing-target cache and invalidation. Timeline root and child and Detail share semantics; native SwiftUI Text owns wrapping, truncation and clicks. Preserve four/two-line previews, three children, metadata and assets, Detail ten-level pagination and delayed loading.

## Alternatives considered

### Swift Markdown parser

Rejected because it would duplicate Logseq syntax and diverge across views.

## Acceptance criteria

- URLs, labeled URLs, nested styles, UUID [[uuid]] references, missing and cyclic references render through shared OCaml runs.
- Code and escaped syntax do not hydrate references; parsing, expansion and retained caches are bounded.
- Actual isolated iOS Simulator fixture verifies appearance, truncation, navigation and links.
- Tests execute RED before GREEN; independent journal-code-review session reports evidence.

## Risks

- The current worker protocol has indexed single-target reads and no batch reference operation. Existing session cache and bounded scheduler must avoid repeated per-row requests. Native Simulator runtime uses the existing complete-object restamp route; physical iPhone acceptance is outside scope.

## Questions

None. User explicitly authorized implementation and Simulator verification, narrowed reference syntax to [[uuid]], then authorized the single app/dune library entry. Locked and spec files remain protected; any necessary lock change requires a separate exact diff.


## Implementation progress

The shared Journal_model.Title AST adapter, cache and expansion budgets are implemented. Timeline root/child use Journal_header.bounded_text; Detail uses the same runs through detail_text. Swift maps runs to AttributedString and native Text; resolved references route through validated chrome extension events. Only UUID Page_ref AST nodes are targets; deprecated Block_ref is literal. Status, properties, assets, pagination and delayed loading retain existing ownership.

Target model/semantics tests pass; locality 116 and Application view 82 pass. Independent journal-code-review has no remaining evidenced source findings. Actual isolated Simulator first frame verifies four/two-line truncation and styles, with missing/cyclic tokens preserved. Actual native XCTest verifies nested-reference navigation, both URL forms opening Safari, missing/cyclic row navigation, root Detail full text and child text beyond Timeline truncation. CJK preview screenshots confirm four visible lines; its AX frame includes host reservation, so acceptance compares the same title with Detail expansion instead of a fixed point ceiling. Fixed XMLm fork and mldoc build in private prefixes; reproducible protected dependency declarations await the authorized upstream core/tool package split and approval of its published fixed commit; the former 22-package whole-package lock proposal is paused and unapplied. The full aggregate test has a hardcoded external-build root lookup failure. Automatic review rejected the conventional repository build symlink retry; it was removed, and the rejected action was not bypassed. All evidence is outside Git. No push, PR, real graph mutation or physical-device installation occurred.

The nested-reference click regression belongs to the pure Title renderer, which has no reducer-event ownership boundary. Its public Title.render output reproduces the defect without DB/effect injection: nested expanded labels retain the outer reference target; explicit normal URL fragments retain their URL. The new assertion failed before the minimal change and passes afterward. GUI tests are the separately requested native feature acceptance.
