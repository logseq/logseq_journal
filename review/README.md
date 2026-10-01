# Journal text-first implementation review

The feature lives in OCaml/LUI. No Swift source, dune file, or spec/ OCaml file was changed. The original checkout and graph files remain untouched. Only the existing simulator received local preview apps; no PR, push, remote merge, or physical-device installation was made.

## Base and scope

The branch starts at c49804c and locally merges official main a33d782, producing base a56c3c6. PR 34 is already in main; PR 35's c49804c loading change remains a dependency not yet in main. Open PR 32 targets the composer-assets branch; its importer fixes were not merged or edited here. The new media view recognizes its additional image extensions but replaces the presentation in OCaml/LUI.

Rows have no disclosure arrow, retain native navigation and swipe actions, clamp long text to three lines with a stable expansion action, show native file-image thumbnails (216 × 151 for galleries), and open native previews. Files use a type label and descriptor size when present. Status and resolved named tags sit below the body and media. Empty metadata produces no footer. Existing native list visible-range events release offscreen media demand; there is no new geometry measurement.

## Real data capability

Task state already comes from normalized block properties. Block tags are UUIDs, so the worker now resolves page titles from the SAME immutable read snapshot, caches repeated lookups within that request, and emits optional tagTitles. Legacy responses omit the optional field and still decode/round-trip. The application caches tag titles by block UUID and feeds the timeline projection; reset clears that cache. Missing tag pages are omitted.

Asset descriptors provide type/version, optional byte size/dimensions, and acquired local files. They do not provide a guaranteed original filename. Cache path names are never presented as filenames. Existing block/child text remains visible, including filenames if that is the real source text. Loading/unavailable attachments show the actual runtime placeholder and Retry. The authorized follow-up fix now delivers Ready reliably. The real graph renders its camera image and an ML file card with actual 47.2 KB metadata. Tapping the real image opens a full native Quick Look preview; the ML file opens the system fallback showing its actual 47 KB size. Quick Look may expose the cache basename in its own title because original filename metadata is unavailable. Richer overview screenshots use explicitly synthetic metadata.

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

## Asset-notification follow-up: resolved

The pure transfer/Core reducers emitted correct availability effects followed by Asset_demand_accepted. The existing Worker adapter put all independent Asset_notice values in one latest-value slot, so acceptance overwrote Ready and different consumers could erase each other's notices. The public coalesced mailbox is the missing ownership boundary; the fix leaves reducer specs unchanged.

The Worker now supports a pure optional merge callback under its existing mailbox lock. The production asset policy stores independent latest facts by full graph scope, consumer/asset, demand admission, upload operation, and capacity. A balanced map keeps insertions O(log n); sorting once at delivery restores retained-fact arrival order. A counter avoids scanning the map for its size. Pending distinct facts are capped at 4096; exhaustion fails explicitly rather than silently discarding notifications. The newest Worker event envelope retains epoch, generation, and push-sequence fencing. Other topics retain latest-value replacement.

Six new public-mailbox checks cover Ready followed by acceptance, multiple assets/consumers/scopes/capacity, retry and admission ordering, independent upload operations, the hard bound, and ordinary snapshot replacement. Five loss/bound tests failed before the implementation; all six now pass, together with the two existing service tests. dune build @all passed. Full dune runtest still reports only the existing literal V.progress boundary mismatch described above.

The fixed production object was linked into the existing fresh Swift scratch build (83.59 seconds), signed, installed, and run only on the existing simulator. Real graph image rendering, full-image Quick Look, file fallback preview, and dismissal back to the list were observed. No trace instrumentation remains. New local evidence: real-assets-fixed.png and real-image-preview-fixed.png. Both are saved privately in Library; exact receipts are in notice-fix-library-delivery.json. The earlier gallery gesture limitation remains a manual check; a computer drag on the isolated preview did not establish a movement result, so no gesture-conflict claim is made.

## Build details

Use PATH=/Users/rcmerci/.opam/logseq-journal-lui/bin:$PATH and OCAMLPATH=/Users/rcmerci/Documents/Codex/2026-09-30/task-3/local-prefix/lib for dune. A copied SwiftPM compiled cache initially failed because its PCH stores an absolute module-cache path. That issue is RESOLVED: full Swift/native source recompilation in new review/swift-clean-build succeeds (2233 target build steps, 138.34s) and review/LogseqJournalClean.app was signed, installed, launched, and its real timeline inspected. Only source checkouts/repositories and workspace-state metadata were cloned into the new scratch directory; no existing compiler caches were deleted or changed. The formerly used relink script remains as historical fallback. The independently generated cache now owns fresh SwiftShims, PCH, modules, native C objects, dependency plugins, LUI backend, and Journal host objects.

Exact full-build command is saved in ../clean-build-command.sh. Logs are ../swift-clean-build.log; final Build of product JournalApp complete confirms success. The clean app binary uses this checkout's new production OCaml complete object via JOURNAL_NATIVE_LINK_INPUTS, plus embedded simulator entitlements. No Swift source was modified.

The isolated fixture entry is review/journal_design_fixture.ml. Temporarily substitute it for app/native_embed.ml, build app/native_embed.exe.o, relink with mode fixture, then restore the production entry. It has its own bundle com.logseq.journal.designpreview and synthetic header. Launch with SIMCTL_CHILD_JOURNAL_DESIGN_ASSETS pointing at fixture assets. It never starts a graph worker or edits user notes. The fixture's displayed descriptor sizes are illustrative metadata, independent of sample asset byte lengths.

Local screenshots: review/journal-overview-ui.png, journal-expanded-ui.png, real-app-ui.png. The original design diagrams and local HTML prototype are in ../design/. Screenshot files and large native build outputs are intentionally excluded from Git. The latest production object is journal-notices-fixed-iossim.o; its successful build log is ../notice-fix-build.log.
