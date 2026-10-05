# Journal text-first timeline items

## Problem

Journal entries currently render body text, child summaries, and task state without a clear hierarchy. The trailing disclosure arrow consumes space and files appear as ordinary text. The reviewed visual proposal 01 uses a white canvas, date headings, body-first rows, visible image previews and quiet metadata.

## Proposal

Implement the user-selected proposal 01 with LUI elements written in OCaml. Keep the existing native backend, graph, date headers, and floating controls. Use LUI file_image, file_preview, horizontal scroll and line-clamp-3; do not add SwiftUI UI code. Root body opens the block; media opens its own preview. Preserve row context menus. Add optional named tags to the existing Worker block read payload by resolving class page titles from the same read snapshot, preserving backward compatibility for payloads without that field. Carry names through graph projection to Journal_model. File cards use actual type and optional descriptor size; when no stable original filename is available use a descriptive type label instead of a cache-path basename.

The PR targets freshly fetched official main a33d7823b55a0cc4c3d78a9b0731ad47c3378b11. The original combined-base local commits remain preserved on a backup branch. PR 35 loading changes and PR 32 importer changes are excluded from the independent feature diff.

## Decision

Implement proposal 01 in OCaml/LUI on current main, with snapshot-resolved named tags, optional actual file sizes, native file preview, and a stable expansion action. Deliver the explicitly authorized draft PR with synthetic screenshots; keep horizontal gesture conflict as a manual verification item.

## Alternatives considered

### Soft cards and media-first rows

The user selected the lighter text-first proposal instead. Card surfaces and the larger media-first spacing are intentionally omitted.

### Custom SwiftUI row

Rejected by the user's explicit instruction to write new UI in OCaml using LUI. Existing built-in LUI backend components provide the required behavior.

## Consequences

The existing native host remains required. Named tag metadata becomes an optional backward-compatible Worker response field. Original attachment names remain unavailable. Real graph files and the original repository are preserved. The implementation builds directly on main and needs no PR 35 dependency. The user explicitly authorized publication as a draft PR; merging and physical-device installation remain outside scope.

## Acceptance criteria

- Timeline rows show no trailing chevron and still open the correct block.
- Body text is primary; long body text can expand and collapse without losing its block identity.
- Local images have real previews; multiple images scroll horizontally with the next image visible.
- Non-image files have a type icon and actual type and size where available; missing names and sizes are not fabricated.
- Task state and resolved tags are secondary, and absent metadata occupies no space.
- All UI implementation changes are in OCaml/LUI; no new SwiftUI UI code, dune changes, or spec/ OCaml changes.
- Run RED tests before implementation, then relevant tests, the workspace build, and simulator build/run and screenshot review.
- Deliver a reviewable draft PR against main. Do not merge, alter user notes, reset the simulator, or install on a physical iPhone.

## Risks

- Horizontal gallery scrolling need actual simulator interaction verification.
- The current descriptor contains no guaranteed filename; type-label fallback is an intentional limitation.
- Private real-graph screenshots remain local; public screenshots must use invented notes and explicit synthetic labels.
- Existing known failing checks must be reported independently from new failures.

## Questions

- Which visual proposal should be implemented? Answered by the user: proposal 01, text-first light grouping, with no right arrow.
- Which UI technology is authorized? Answered by the user: LUI with OCaml, keeping necessary existing native bridges.
- May this be published or installed on the iPhone? The user explicitly authorized a PR. No physical-device installation or merge is authorized.

## Implementation evidence

Implemented in OCaml/LUI and validated by nine mounted-UI checks, fourteen Worker application integration cases, protocol round trips, and successful workspace build. Actual iOS simulator screenshots and native PDF preview, expansion and collapse were reviewed. See review/README.md for local artifacts, base/PR dependencies, and reproducible host linking. Full runtest has the unchanged baseline V.progress source assertion failure. Horizontal gallery drag remains an explicit manual verification item because the mouse-control tool reports noWindowsAvailable. File names are unavailable from the descriptor; type and optional actual size are used honestly. Draft PR publication is authorized; no physical-device installation or merge occurs.


## Follow-up validation

The separately documented Ready notification fix resolves the integration blocker: five public-mailbox cases failed first, all eight service checks now pass, and a real graph image and actual file metadata reached the combined-base simulator. Full-image Quick Look and return to the list were verified. Private evidence remains local. Publication first moves only the feature and fix commits onto current main, preserving the original combined history on a local backup branch, and reruns affected checks and simulator compilation there. No PR 35 Swift changes are included.
