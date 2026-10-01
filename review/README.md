# Journal text-first implementation review

The feature lives in OCaml/LUI. No Swift source, dune file, or spec/ OCaml file was changed. The original checkout and graph files remain untouched. Only the existing simulator received local preview apps; no PR, push, remote merge, or physical-device installation was made.

## Base and scope

The branch starts at c49804c and locally merges official main a33d782, producing base a56c3c6. PR 34 is already in main; PR 35's c49804c loading change remains a dependency not yet in main. Open PR 32 targets the composer-assets branch; its importer fixes were not merged or edited here. The new media view recognizes its additional image extensions but replaces the presentation in OCaml/LUI.

Rows have no disclosure arrow, retain native navigation and swipe actions, clamp long text to three lines with a stable expansion action, show native file-image thumbnails (216 × 151 for galleries), and open native previews. Files use a type label and descriptor size when present. Status and resolved named tags sit below the body and media. Empty metadata produces no footer. Existing native list visible-range events release offscreen media demand; there is no new geometry measurement.

## Real data capability

Task state already comes from normalized block properties. Block tags are UUIDs, so the worker now resolves page titles from the SAME immutable read snapshot, caches repeated lookups within that request, and emits optional tagTitles. Legacy responses omit the optional field and still decode/round-trip. The application caches tag titles by block UUID and feeds the timeline projection; reset clears that cache. Missing tag pages are omitted.

Asset descriptors provide type/version, optional byte size/dimensions, and acquired local files. They do not provide a guaranteed original filename. Cache path names are never presented as filenames. Existing block/child text remains visible, including filenames if that is the real source text. Loading/unavailable attachments show the actual runtime placeholder and Retry. The actual simulator graph's attachments remain in “Waiting for file”. Diagnostic evidence now shows that both assets are already Ready in the background policy, both UI media demands are sent with graph generation 1 and accepted, but the UI receives no Ready notice. See the existing notification blocker below. Richer screenshots use explicit synthetic metadata.

## Verification

- New tests were run RED before implementing no-chevron, long-text expansion, LUI galleries/previews, file type/actual-size presentation, unavailable-file retry, and tag propagation. The simulator caught an unsupported text padding property; a regression test failed first, then passed with a supported container.
- Final journal_semantics_test: 9 checks pass, including repeated expand/collapse using the same retained action.
- Worker application integration: 14 cases pass, including response → projection → mounted named tags.
- Protocol tests pass, including tagged and legacy response round trips.
- dune build @all succeeds. Full dune runtest has ONE pre-existing source_boundary_test failure: it requires literal V.progress in unchanged app/journal_timeline.ml, which already uses V.loading on the combined base. It was not suppressed or edited.
- spec-dev-tool check --all reports one existing invalid decision document (2026-09-28-bottom-lui-capsules.md lacks Problem, Alternatives considered, and Consequences). This feature decision itself validates.
- Both production entry and synthetic entry were built, linked, signed, installed, and run on iOS 26.1 simulator D9F8152B-CC8F-49F6-A931-F4BF14BF364F.
- Arrow-free real graph row was tapped in the simulator and opened the correct block ID/source; Back returned to the timeline without changing notes.
- Actual simulator interface verified expansion, collapse, native PDF content preview and dismissal, and preserved expansion state on return. Thumbnails are actual decoded images, not mock UI. Horizontal drag verification remains manual: the computer-use mouse operation returns noWindowsAvailable although AX actions work. Unit coverage verifies horizontal Scroll and native file-preview nodes; do not claim gesture conflict is verified.

## Existing asset-notification blocker

The new OCaml/LUI media on-appear handlers issue real foreground demand. Temporary local-only trace confirmed two matching cached asset UUIDs in background policy Ready notices, then both media requests with send accepted=true; only the last Asset_demand_accepted push reached the UI. Source inspection identifies the existing cause: logseq_db_worker/lui/logseq_db_worker_lui_service.ml publishes every Asset_notice into the same asset_topic; journal_worker.ml stores one latest event per topic in a Coalesced mailbox. pure_reducer/core.ml emits availability effects followed by Asset_demand_accepted, so acceptance overwrites Ready before the client drains the topic. Multiple consumers can overwrite each other's notices too. These lines are unchanged from base a56c3c6. Thus this is an existing event-delivery defect exposed by the new UI, rather than a pending download or failed image rendering. Fixing the reliable asset notice transport is a separate unresolved integration requirement; this design commit does not claim end-to-end real graph file availability works. Temporary instrumentation was restored immediately and is absent from the commit.

## Build details

Use PATH=/Users/rcmerci/.opam/logseq-journal-lui/bin:$PATH and OCAMLPATH=/Users/rcmerci/Documents/Codex/2026-09-30/task-3/local-prefix/lib for dune. A copied SwiftPM compiled cache initially failed because its PCH stores an absolute module-cache path. That issue is RESOLVED: full Swift/native source recompilation in new review/swift-clean-build succeeds (2233 target build steps, 138.34s) and review/LogseqJournalClean.app was signed, installed, launched, and its real timeline inspected. Only source checkouts/repositories and workspace-state metadata were cloned into the new scratch directory; no existing compiler caches were deleted or changed. The formerly used relink script remains as historical fallback. The independently generated cache now owns fresh SwiftShims, PCH, modules, native C objects, dependency plugins, LUI backend, and Journal host objects.

Exact full-build command is saved in ../clean-build-command.sh. Logs are ../swift-clean-build.log; final Build of product JournalApp complete confirms success. The clean app binary uses this checkout's new production OCaml complete object via JOURNAL_NATIVE_LINK_INPUTS, plus embedded simulator entitlements. No Swift source was modified.

The isolated fixture entry is review/journal_design_fixture.ml. Temporarily substitute it for app/native_embed.ml, build app/native_embed.exe.o, relink with mode fixture, then restore the production entry. It has its own bundle com.logseq.journal.designpreview and synthetic header. Launch with SIMCTL_CHILD_JOURNAL_DESIGN_ASSETS pointing at fixture assets. It never starts a graph worker or edits user notes. The fixture's displayed descriptor sizes are illustrative metadata, independent of sample asset byte lengths.

Local screenshots: review/journal-overview-ui.png, journal-expanded-ui.png, real-app-ui.png. The original design diagrams and local HTML prototype are in ../design/. Screenshot files and large native build outputs are intentionally excluded from Git.
