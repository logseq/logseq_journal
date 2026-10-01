# Journal text-first timeline items

## Problem

Journal entries currently render body text, child summaries, and task state without a clear hierarchy. The trailing disclosure arrow consumes space and files appear as ordinary text. The reviewed visual proposal 01 uses a white canvas, date headings, body-first rows, visible image previews and quiet metadata.

## Proposal

Implement the user-selected proposal 01 with LUI elements written in OCaml. Keep the existing native backend, graph, date headers, and floating controls. Use LUI file_image, file_preview, horizontal scroll and line-clamp-3; do not add SwiftUI UI code. Root body opens the block; media opens its own preview. Preserve row context and swipe actions and prevent full-swipe deletion. Add optional named tags to the existing Worker block read payload by resolving class page titles from the same read snapshot, preserving backward compatibility for payloads without that field. Carry names through graph projection to Journal_model. File cards use actual type and optional descriptor size; when no stable original filename is available use a descriptive type label instead of a cache-path basename.

The original repository is untouched. Official main was a33d7823b55a0cc4c3d78a9b0731ad47c3378b11. PR 35 was merged to PR 34's branch at c49804cb25fb2cacbdf5090f6c6c1b0d9d42b196 rather than main. The isolated checkout merges current main into c49804c and records that combined commit as the implementation base. PRs 20 and 32 remain open; neither is merged. PR 32's importer copying/request-token fixes are outside this work.

## Decision

Implement proposal 01 in OCaml/LUI on the isolated combined base, with snapshot-resolved named tags, optional actual file sizes, native file preview, and a stable expansion action. Deliver a local commit and simulator screenshots; keep horizontal gesture conflict as a manual verification item.

## Alternatives considered

### Soft cards and media-first rows

The user selected the lighter text-first proposal instead. Card surfaces and the larger media-first spacing are intentionally omitted.

### Custom SwiftUI row

Rejected by the user's explicit instruction to write new UI in OCaml using LUI. Existing built-in LUI backend components provide the required behavior.

## Consequences

The existing native host remains required. Named tag metadata becomes an optional backward-compatible Worker response field. Original attachment names remain unavailable. Real graph files and the original repository are preserved. The implementation depends on PR 35's loading fixes until that change reaches main. No PR or remote publishing is created.

## Acceptance criteria

- Timeline rows show no trailing chevron and still open the correct block.
- Body text is primary; long body text can expand and collapse without losing its block identity.
- Local images have real previews; multiple images scroll horizontally with the next image visible.
- Non-image files have a type icon and actual type and size where available; missing names and sizes are not fabricated.
- Task state and resolved tags are secondary, and absent metadata occupies no space.
- All UI implementation changes are in OCaml/LUI; no new SwiftUI UI code, dune changes, or spec/ OCaml changes.
- Run RED tests before implementation, then relevant tests, the workspace build, and simulator build/run and screenshot review.
- Deliver a local reviewable commit/diff. Do not publish a PR, merge, alter user notes, reset the simulator, or install on a physical iPhone.

## Risks

- Horizontal gallery scrolling and row swipe actions need actual simulator interaction verification.
- The current descriptor contains no guaranteed filename; type-label fallback is an intentional limitation.
- The combined base includes PR 35 changes not currently in main, so review must distinguish that dependency from this feature.
- Existing known failing checks must be reported independently from new failures.

## Questions

- Which visual proposal should be implemented? Answered by the user: proposal 01, text-first light grouping, with no right arrow.
- Which UI technology is authorized? Answered by the user: LUI with OCaml, keeping necessary existing native bridges.
- May this be published or installed on the iPhone? Not authorized; this delivery is local for review and simulator verification only.

## Implementation evidence

Implemented in OCaml/LUI and validated by nine mounted-UI checks, fourteen Worker application integration cases, protocol round trips, and successful workspace build. Actual iOS simulator screenshots and native PDF preview, expansion and collapse were reviewed. See review/README.md for local artifacts, base/PR dependencies, and reproducible host linking. Full runtest has the unchanged baseline V.progress source assertion failure. Horizontal drag/swipe conflict remains an explicit manual verification item because the mouse-control tool reports noWindowsAvailable. File names are unavailable from the descriptor; type and optional actual size are used honestly. No remote publishing or physical-device installation occurred.

