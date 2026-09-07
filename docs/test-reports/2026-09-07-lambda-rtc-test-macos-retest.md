# Lambda-RTC-test macOS current-worktree retest

## Scope and status

This is a continuation of the [September 6 audit](2026-09-06-lambda-rtc-test-macos-audit.md), executed on September 7, 2026, Asia/Shanghai. The request authorizes read/write testing; the user subsequently explicitly approved clearing the backed-up local copy and redownloading. Testing of the available native operation surface and the issue inventory are complete. Functional acceptance **fails** because the current Release reproduces fatal Todo Capture, stuck outgoing sync, stale child previews, inaccessible detail operations, and inaccessible Capture labels. No fixes are included.

- Graph: `Lambda-RTC-test`, UUID `f5271dfc-897a-43c7-b116-04832d13b70b`.
- Source HEAD: `de06ba1`, including the pre-existing working-tree changes to page-tree reads, snapshot checksums, Worker contracts, and related tests.
- Built successfully using `opam exec -- bonsai-flutter build macos --profile=release`. Relevant framework pins are Git pins.
- Native UI: `flutter/build/macos/Build/Products/Release/bonsai_flutter_logseq_journal_host.app`.
- Independent peer: the existing Chrome `https://app.logseq.com/#/` tab, visibly on the target graph.
- Test records use `QA-LAMBDA-20260907-1648`. Only records created for this retest were edited. No production implementation, spec, Dune, or framework source was changed by the retest.
- Private evidence, source/binary hashes, database backups, and probe results: `/tmp/logseq-lambda-retest-20260907/`.
- Before mutation: SQLite integrity `ok`, cursor 31, checksum `f17dea4506a39ef5`, active durable state, empty outbox.

The original running process used yesterday's binary. Its initially sparse accessibility tree was not a blank-window defect: a screenshot showed the timeline, and interacting with Account populated accessibility normally. The retest then quit that process and launched the newly built Release.

## Current findings

### L01 — Direct Todo Capture still causes a fatal duplicate-key UI error (high)

On the current Release, capture the test Todo, enable task intent, and save. The entire UI entered `BonsaiRuntimeException(fatalError, duplicateKey)` within 1,410 ms. The duplicated key was `block:01a07b0f-219a-8d0e-87a0-4c10c835d057`, at child indices 1 and 2 under `Sliver_varied_extent[key="journal-timeline-list"]`.

The independent peer received the block as plain text. Local evidence retained a submitted `insertBlocks` and queued `setTaskStatus`. This reproduces L01 on the newly built code; it is not inferred from yesterday's report. Evidence: `todo-crash.sqlite`, `todo-crash.json`.

### L02 — Restart restores presentation but does not unblock the mutation queue (high)

Restart produced a readable timeline within 667 ms, showing the optimistic Todo. The insertion later reached local cursor 33 but stayed in `deleteBarrierRejectedPendingAuthoritative`, through cursor 33, with observed origin cursor 33. Its Todo status remained queued. Deleting this test Todo after the Undo window hid it locally but added a queued `deleteBlocks`; the peer still retained the plain block.

At 16:52, cursor 33/checksum `b6c7521a81d07dc2` and three outbox entries remained. Later incoming peer changes advanced the mirror to cursor 41 while the outbox still contained all three entries. Therefore incoming reads can progress while outgoing writes remain stuck. Diagnostics continued to report Pulling / Ready / Open with the real nonzero outbox metrics. It did not expose an actionable recovery control for this queue.

The complete local database and queue were backed up before requesting permission for the App's Delete local graph copy/redownload recovery. After approval, a fresh `approved-before-recovery.sqlite` backup was taken. The reset recovered a clean authoritative mirror; the abandoned queued status/delete are not counted as successful operations. Evidence: `before-recovery.sqlite`, `before-recovery.json`, and `approved-before-recovery.json`.

### L03 — Collapsed child preview still retains obsolete incoming text (medium)

Parent: `01a07b0e-26b8-84a7-9a74-08962031460f`. Child: `6a9e7bb7-1896-4aa6-bd9d-2a59d23de32c`.

The peer's child read `QA-LAMBDA-20260907-1648 child-v1`. macOS expansion displayed exactly that current child, but its collapsed preview retained the earlier split text `1648 peer-edited ...`. Incoming parent-title changes did refresh the parent. This reproduces the preview-specific failure rather than a complete incoming-sync outage.

A subsequent isolated edit changed only the child to `child-v2`. The already expanded native child refreshed to `child-v2`; collapsing still restored the same obsolete split-text preview. This independently confirms that the fixture-setup caret issue is not required for a later preview refresh to fail.

Returning to the graph picker and reopening the same local graph finally refreshed the collapsed preview to `child-v2`. Ordinary collapse/expand had not refreshed it.

During fixture setup, keyboard automation split the test parent at an unintended caret position. Both parent and child were then explicitly assigned their intended complete values through visible text fields before comparing the current child with its retained preview. This setup artifact is not claimed as an App defect, and no original user record was involved.

### L05 — Detail reading, source editing, and child creation remain unreachable (high)

Double-clicking the new native text row did not change the UI. Source inspection still found no timeline caller of `Journal_routes.open_detail`. Consequently full detail reading, native source update, native child creation, recursive navigation, and the detail task toggle cannot be marked passed. Child fixture edits in the peer do not count as native write coverage.

### L08 — Capture's icon controls still lack meaningful accessibility labels (medium)

The empty Capture sheet exposed task intent as ``; after input, Save appeared as ``. Enabling task intent changed its visible background but did not change its announced accessibility state. The source contains intended labels, but the actual native accessibility tree did not expose them on these controls.

### Historical findings not independently re-executed in this retest

The original report also records L04 (persistent Failed runtime after authoritative convergence), L06 (sign-out leaves no sign-in form), and L07 (first encrypted-graph open exposes `wrappedGraphKeyUnavailable`). Their evidence remains historical; this current retest does not claim they are fixed or freshly reproduced. A cached-key redownload does not reproduce a never-downloaded graph's key setup.

## Native observations and timings

Times include automation dispatch and UI observation overhead. They are observed upper bounds, not profiler timings, percentile measurements, or exact rendering latency. The 667 ms restart used a contiguous launch-and-observe call and showed both test rows; background history/sync work was still active. An earlier launch was sampled with a gap and is only bounded by 7.107 s, so it is not used as an exact startup benchmark.

| Operation | Current observation |
| --- | --- |
| Restore last graph on launch | Passed; directly opened target timeline |
| Restart after fatal Todo UI error | Readable test rows by 667 ms; queue did not recover |
| Open Capture | 1,062 ms |
| Unicode/multiline plain Capture | Saved row by 843 ms; full Chinese text, emoji, and second line verified on peer |
| Direct Todo Capture | Fatal UI error by 1,410 ms |
| Delete stage | 740 ms; row hidden and Undo exposed |
| Plain-record delete and immediate Undo | 1,584 ms for both; complete row restored |
| Committed delete after crash | Local row hidden; delete queued and peer retained it |
| Child disclosure arrow | Current direct child by 517 ms |
| Child collapse | 523 ms |
| History scroll, three pages | Additional history visible by 544 ms |
| Incoming parent edit | Refreshed in the running timeline; no precise sync latency measured |
| Incoming child edit | Expanded child current; collapsed preview stale |
| Cmd+F | No search UI appeared |
| Native detail double-click | No navigation occurred |
| Settings read | Populated typography settings by 615 ms |
| Empty Capture | No Save control exposed |
| Dismiss/reopen unsaved draft | Complete draft visibly retained; subsequently cleared without Save |
| Clear draft | Save control disappeared; no additional outbox record |
| Return to graph picker | Target graph and catalog visible by 624 ms |
| Refresh graph catalog | Action accepted and catalog stayed visible; no distinct completion signal, so network refresh latency is not claimed |
| Reopen target from picker | Readable timeline by 823 ms, without download or password entry; preview refreshed, but all three outbox entries remained stuck |

The first attempted Todo Undo missed the UI's timer while tool calls were separated. That expired element is an automation timing limitation, not an App failure. The separate plain-record test clicked the dynamically observed Undo control within a single tool invocation and passed.

There is no standalone search, page browser, date jump, attachment-open, property editor, move, indent, or outdent surface exposed in the inspected native application. These are capability gaps. Offline/reconnect writes and a concurrency matrix have not been exercised by this retest.

## Complete journal read traversal on a private copy

The previous downloaded graph was backed up through SQLite's backup API before this retest wrote any records. A standalone probe linked the current production libraries and used public `Database` interfaces against that copy. Its historical journal call was updated to provide the now-required `from_day=0` and `through_day=99999999` bounds. No `.mli` was bypassed or modified. Only the disposable copy's SQLite journal mode was changed for standalone opening.

All **512 journals** and **6,803 unique journal tree blocks** were enumerated. Every journal page lookup and every tree-member block lookup succeeded; tree traversal found no duplicate UUIDs. A deliberately absent UUID returned Missing_block. The additional journal relative to September 6 is the existing September 7 journal, already present before this retest.

| Public operation | Calls | Median ms | p95 ms | Maximum ms |
| --- | ---: | ---: | ---: | ---: |
| Open | 1 | 22.604 | 22.604 | 22.604 |
| Journal list, limit 200 | 3 | 19.743 | 52.682 | 52.682 |
| Page tree, limit 200 | 513 | 1.095 | 3.684 | 14.909 |
| Direct children, limit 200 | 512 | 0.445 | 1.220 | 4.815 |
| Page lookup | 512 | 0.240 | 0.373 | 0.759 |
| Block lookup, batches up to 50 | 137 | 15.398 | 20.230 | 28.282 |

These API timings are supplemental local measurements, not native App latency or evidence that every record was individually visible on screen. They indicate responsive reads in this dataset; they do not prove an unspecified global SLO.

The original audit's independent 8,649,575-byte download, 32,642 framed rows, exact frame boundaries, physical reference integrity, root datom count, and matching server checkpoint evidence remains available in the linked report and its private evidence directory. The current-version redownload is independently covered below.

## Approved recovery, complete redownload, and healthy writes

The user approved recovery after the initial blocked audit. At 17:11 the current database was backed up again; it still had cursor 43 and exactly the three known test operations. Delete local graph copy returned to the picker in 645 ms, retained the remote graph and cached encryption key, and removed the abandoned local queue.

Redownload began at `2026-09-07T09:12:00.632Z`. At 19.606 s, native UI reported 8,657,537 downloaded bytes and still displayed Downloading graph. Readable SQLite publication was observed at `09:12:21.523454Z`, **20.891 s** after selection. Native timeline was observed by **35.629 s**. This latter value includes a gap between observations and is an upper bound, not an exact presentation timestamp. No password prompt appeared; cached-key reuse worked.

The downloaded mirror was 69,087,232 bytes, with SQLite integrity `ok`, 48,988 physical KVS rows, and zero missing physical references. Its checkpoint was cursor 43, checksum `f0e679611c936e85`, active state, and empty outbox. A private-copy probe opened all **512 journals and 6,806 unique tree blocks**, including the three test blocks, with no missing page/block lookups or duplicate tree UUIDs. Maximum observed journal-list, page-tree, children, page-lookup, and block-batch times were respectively 52.869, 17.714, 5.075, 0.816, and 28.398 ms. Evidence: `redownload.sqlite`, `redownload-publication.json`, `redownload-read-results.txt`.

For a stronger whole-graph comparison, a separate probe used the public `Logseq_sqlite_storage.restore_database` API on private copies and enumerated production Datascript EAVT facts. It applied the persisted transaction tail through the real restore implementation and compared every entity/attribute/value fact, excluding transaction IDs. All **168,748 logical datoms matched exactly** between the pre-reset authoritative mirror and the fresh download. This establishes complete logical content preservation across redownload rather than relying only on matching checkpoints. Evidence: `facts_probe.ml`, `restored-logical-comparison.json`, and the private `*-facts.jsonl` files.

An initial raw base-tree comparison had omitted address 1's transaction tail and incorrectly suggested stale persisted titles/counts. That interpretation was explicitly withdrawn after inspecting the storage contract and checking the production restore result. It is **not an additional App issue**. Raw base-tree counts and residual base-tree titles are not the current logical database when a tail exists; `redownload-integrity.json` and `cleanup-integrity.json` are superseded for logical-content claims by `restored-logical-comparison.json`.

Healthy status tests used the recovered plain Todo test record. All seven operations received applied receipts; the server cursor advanced from 43 to 50 and the outbox emptied. Native state showed each selected status. The peer was checked at the final cleared state; intermediate peer icons were not individually sampled in this retest.

| Recovery operation | Result and observed duration |
| --- | --- |
| Backlog | Selected state visible by 835 ms after selecting the menu item |
| Todo | 2,068 ms including swipe and picker |
| Doing | 2,502 ms including swipe and picker |
| In review | 2,515 ms including swipe and picker |
| Done | 2,510 ms including swipe and picker |
| Canceled | 2,499 ms including swipe and picker |
| Clear | 2,509 ms including swipe and picker |
| Delete standalone test Todo | Accepted through cursor 51; peer confirmed disappearance; the different expanded parent retained its visible child |
| Parent/subtree delete and immediate Undo | 2,102 ms including swipe; parent and expanded child restored together |
| Commit parent/subtree deletion | Accepted through cursor 52; peer confirmed both parent and child disappeared |
| Normal quit/restart after cleanup | Readable target timeline by 685 ms, with no reappearance of deleted test records |

## Final state, coverage, and issue inventory

All three retest blocks were removed through normal native deletion after recovery. The independent peer confirmed their absence. At 17:17:58, durable state was active, cursor **52**, checksum **`f17dea4506a39ef5`**, and outbox count **0**. The checksum equals the retest's cursor-31 baseline. Nine post-recovery mutation receipts were applied: seven status changes and two deletions. The earlier abandoned queue remains backed up as failure evidence.

Production restoration of the baseline and final private copies found **168,726 logical datoms** in each and no remaining test titles. The only logical change to original data was the containing journal's `block/updated-at` value, which normal child writes update. This is not a byte-for-byte restoration claim. Both SQLite integrity and physical-reference checks passed. Final diagnostics after restart showed Offline / Ready / Open with all four outbox/payload metrics zero; this records the observed phase and is not a claim of a sustained Current phase or a deliberately tested offline-reconnect scenario.

The operation audit covers initial encrypted download evidence, current redownload, completeness, last-graph startup, graph catalog/reopen, timeline pagination, point and structure reads, child disclosure, incoming updates, plain/Unicode/multiline Capture, direct Todo failure, all exposed status values, standalone and subtree delete/Undo, drafts, settings, and diagnostics. Detail reading/source editing/child creation are failed as unreachable native operations. Unsupported search/page/attachment/property/move/indent/outdent surfaces and unexecuted network/concurrency scenarios remain explicitly identified rather than marked passed.

The combined issue inventory retains eight findings from the original audit:

| ID | Severity | Current evidence status |
| --- | --- | --- |
| L01 | High | Direct Todo Capture fatal duplicate key reproduced on current Release |
| L02 | High | Outgoing queue stuck across restart/reopen; reset recovered it |
| L03 | Medium | Incoming child preview stale; reopening graph refreshed it |
| L04 | High | Historical persistent Failed phase after authoritative convergence; not independently re-executed here |
| L05 | High | Native detail, source update, and child creation still unreachable |
| L06 | High | Historical missing sign-in form after sign-out; not independently re-executed here |
| L07 | Medium | Historical internal key error on first encrypted graph open; cached-key recovery passed here |
| L08 | Medium | Capture accessibility labels/selected state still missing in native output |

Current reads and recovered ordinary writes completed promptly in these samples. First download/import took tens of seconds and exposes limited phase detail; exact import phase costs and percentile latency were not measured. Todo Capture and its resulting queue fail functional and time-bounded completion regardless of ordinary-read timings. No universal performance SLO was supplied or inferred.

Validation: current macOS Release build, pre-reset and redownload public journal-read probes, production full-storage restoration comparisons, `spec-dev-tool check --all`, and `git diff --check` passed. No new regression tests or implementation fixes were added as part of this audit. The App is left running on the target graph with an empty outbox; private recovery evidence is retained.
