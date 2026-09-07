# Lambda-RTC-test macOS Read and Write Audit

## Scope and environment

- Main test: 2026-09-06, Asia/Shanghai; final app-state recheck: 2026-09-07.
- Target: `Lambda-RTC-test`, graph UUID `f5271dfc-897a-43c7-b116-04832d13b70b`, encrypted, schema 65.33.
- macOS 26.6.2 (25G83), Apple M4 Max, 64 GiB RAM.
- Source HEAD: `87b47abacd3829afa65f688b6fda1520775023d5`. Existing uncommitted row-rendering and semantics-test changes were retained.
- Fresh Release build: `opam exec -- bonsai-flutter build macos --profile=release`, successful. Installed OPAM framework pins were Git pins.
- App: `flutter/build/macos/Build/Products/Release/bonsai_flutter_logseq_journal_host.app`.
- Actual native UI was tested through accessibility and visible controls. The existing Chrome `https://app.logseq.com/#/` client on the same graph served as an independent sync peer.
- The request initially prohibited graph writes, then explicitly expanded to read/write testing and authorized local deletion/redownload for otherwise unrecoverable errors. Graph writes began only after that expansion.
- Test records use `QA-LAMBDA-20260906-2121`. Existing user content was not intentionally edited. No implementation, spec, dune, or framework files were changed by this audit.
- Credentials, encrypted payloads, and unrelated graph content are omitted from this report. Private evidence and recovery backups are under `/tmp/logseq-lambda-read-audit-20260906/`.

## Result

The graph downloaded and passed structural and checkpoint checks. Ordinary reads, plain and Unicode multiline Capture, and status changes worked. Creating a Todo directly from Capture reproducibly caused a fatal duplicate-key rendering error, including after a clean redownload. A related synchronization recovery sequence left subsequent operations queued across restart. Detail operations have no reachable timeline entry. Child previews can remain stale after incoming edits.

## Download and read integrity

Before test mutations:

- The independent server artifact and the app download both contained 8,649,575 compressed bytes.
- The server advertised 32,642 snapshot rows. Independent framed-artifact inspection found exactly 32,642 unique, ordered addresses, four complete frames, root row 0 and tail row 1, and no trailing partial frame. One gzip layer expanded to 30,272,307 bytes.
- Local SQLite occupied 69,009,408 bytes and contained 48,965 physical KVS rows after import/unprotection. Physical row count is not expected to equal the encrypted artifact's row count after rewriting.
- `PRAGMA integrity_check` returned `ok`; every physical address reference resolved.
- The local EAVT root advertised 168,716 datoms. Traversing its reachable leaves found that exact count: 18,412 entities, 18,399 UUID-bearing entities, and 511 journal pages spanning 2022-06-09 through 2026-09-06.
- Server and local checkpoint matched at cursor 1, checksum `b354899130018f49`; local status was active and outbox count was zero.
- The production public `Logseq_overlay_db.Database` interface was additionally exercised against an isolated copy of the downloaded graph. It enumerated all 511 journal pages and all 6,803 journal tree members, with no duplicate tree UUIDs, missing page lookups, or missing block lookups. This is supplemental API evidence, not a claim that every record was individually viewed in the native window.
- The isolated copy needed its SQLite journal mode changed from WAL to DELETE before a standalone read-only inspection could open it without copied WAL/SHM sidecars. Only the probe copy was changed; app storage was untouched by the probe.

These checks establish framed download completeness, reachable storage integrity, journal read coverage, and agreement with the server checkpoint. They do not establish that unsupported attachment, search, or detail UI exists.

## Timing

Native interaction measurements include automation dispatch and accessibility observation overhead. Values are observed completion upper bounds unless an interval is explicitly given. They are not frame-profiler measurements or p95 UI latency.

| Operation | Observation |
| --- | --- |
| Independent authenticated graph catalog GET | 0.513 s |
| Independent snapshot metadata GET | 1.715 s |
| Independent snapshot artifact transfer | 2.611 s for 8,649,575 bytes |
| First open | Immediately exposed `wrappedGraphKeyUnavailable`; required Continue online |
| First unlock/import | Still downloading at 20.176 s; timeline observed by 41.475 s after Unlock. Manual/tool gaps are excluded from any claim of exact latency |
| First local warm restart | First readable timeline observed by 0.851 s, initially with further entries still loading |
| Recovery restart | Complete visible test rows observed by 4.350 s in one run; another sparsely observed run was only bounded by 11.089 s |
| Diagnostics | 0.629 s, Current / Ready / Open and four populated admission metrics |
| Child expansion | 0.647 s via the visible disclosure arrow |
| Child collapse | Approximately 0.51 s |
| History scrolling | 0.437–0.566 s for observed scroll operations; loaded additional entries |
| Plain Capture | 0.826 s to visible saved row |
| Unicode multiline Capture | 1.050 s to visible saved row; complete content reached peer |
| Status selection | Backlog 1.572 s; Todo 1.575 s; Doing 1.591 s; In review 1.609 s; Done 1.609 s; Canceled 1.601 s; Clear 1.633 s |
| Delete and immediate Undo | 1.680 s for both actions; row restored |
| Delete local copy | 0.659 s to graph picker |
| First recovery redownload | Started 21:33:47.537; database created at 21:34:03.264 and final observed modification at 21:34:08.475; timeline confirmed by 58.353 s. File timestamps are not a substitute for the timeline-presented event |
| Second recovery redownload | Started 21:37:19.364; published readable database detected at 21:37:39.799, approximately 20.435 s. No password prompt; cached key reuse worked |
| Settings | 0.664 s to populated typography settings |
| Healthy Todo Capture | Fatal duplicate-key screen observed 1.201 s after Save |

The API probe measured the actual production implementation on the isolated graph copy:

| Read | Calls | Median | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Open database | 1 | 52.135 ms | 52.135 ms | 52.135 ms |
| Journal list, limit 200 | 3 | 444.804 ms | 459.011 ms | 459.011 ms |
| Page tree, limit 200 | 512 | 4.360 ms | 23.583 ms | 146.659 ms |
| Direct children, limit 200 | 511 | 0.829 ms | 2.784 ms | 11.641 ms |
| Page lookup | 511 | 0.249 ms | 0.398 ms | 0.896 ms |
| Block lookup, batches up to 50 | 137 | 16.215 ms | 20.661 ms | 30.092 ms |

Basic local reads and interactions completed without a sustained hang in these samples. Initial import was substantially slower than raw transfer, but sampling does not isolate crypto, import, and rendering costs precisely. A general claim that every operation meets a specified performance SLO is not supported; no SLO was supplied.

## Findings

### L01 — Todo Capture reproducibly destroys the running UI (high)

From a healthy, freshly redownloaded graph with an empty outbox:

1. Open Capture.
2. Enter `QA-LAMBDA-20260906-2121 todo-healthy`.
3. Toggle the lower-left task-intent button on.
4. Save.

Within 1.201 s, the app displayed `BonsaiRuntimeException(fatalError, duplicateKey)` for `block:fed794f8-28f3-45ad-8fe8-3e51629e7a78`. The candidate timeline contained that same key at child indices 1 and 2. The error path ends at `Sliver_varied_extent[key="journal-timeline-list"]`.

An earlier Todo Capture after a sync failure produced the same error for `d7edb2e4-d00a-4e7e-8114-fb34a18c07d5`, at child indices 0 and 1. The clean-redownload reproduction removes the earlier failure as a necessary precondition.

Restart restored the UI and the optimistic Todo row. The peer initially received only the inserted plain block. Local evidence retained a submitted `insertBlocks` and queued `setTaskStatus`. Evidence: `healthy-todo-crash-evidence.json`, `fatal-duplicate-key-evidence.json`, and SQLite backups in the private evidence directory.

### L02 — A submitted insert does not recover and blocks later writes (high)

After the first Todo crash, restart and submit deletion of that test task after separately verifying Undo.

At 21:33:13, local cursor remained 24 and three records were still pending:

1. `insertBlocks`: `deleteBarrierRejectedPendingAuthoritative`, through cursor 24.
2. `setTaskStatus`: queued.
3. `deleteBlocks`: queued.

The peer still contained the inserted block without the queued Todo state or deletion. The task disappeared locally after the delete undo window, so local presentation alone would falsely suggest successful deletion. Restart had recovered the UI but had not recovered synchronization. Evidence: `stuck-delete-evidence.json` and `before-recovery.sqlite`.

Local copy deletion and redownload recovered a clean authoritative mirror, preserving cached encryption keys. The abandoned local queue was backed up first. Its unsent status/delete must not be reported as successful sync.

### L03 — Incoming child text updates do not refresh the collapsed preview (medium)

The test parent is `f535b2b1-1616-4e6d-87ab-34859cc8cc06`; child is `6a9d6946-f465-440a-b6f6-f7c5cf5b8742`.

Edit the child on the peer and wait for local authoritative storage to receive it. The expanded direct-child row showed `QA-LAMBDA-20260906-2121 child-from-peer`, while the collapsed parent preview still showed the earlier `-2121 edited-from-peer`. Collapse/expand did not repair the preview. A subsequent `child-v2` edit also left the old preview until an unrelated local Capture refreshed the feed.

Parent title edits did refresh live. The defect is therefore narrower than a complete failure to consume incoming sync.

### L04 — Sync stays Failed after an authoritative transition error despite matching checkpoints (high)

After incoming peer edits and a successful Unicode multiline Capture, the timeline displayed `The authoritative transition was rejected.` Diagnostics stayed Failed / Ready / Open with all outbox metrics zero.

At 21:25:50 both server and local state were cursor 23, checksum `ea4dd4f5e2029f87`; local durable status was active with no last error. The capture had a server acceptance receipt through cursor 22 and the peer displayed its complete content. The failure remained visible over subsequent checks. There was no actionable retry or detailed error control on the timeline.

This audit does not establish which event ordering caused the rejected transition. It establishes a persistent failed runtime state after successful authoritative convergence, and poor recovery/error visibility. Evidence: `post-paste-sync-evidence.json`, `post-paste-server.json`.

### L05 — Block detail, source editing, and child creation are unreachable (high)

Single click, double click, and native accessibility activation of a newly created text row did not enter detail or editing. A row with children offered disclosure only. Source inspection confirmed no caller of `Journal_routes.open_detail` in `app/`, although detail rendering and save/add-child/task handlers exist.

Consequences: the macOS app cannot reach full detail reading, edit source, create a child of an existing block, or use the detail task toggle. Long text is limited to timeline previews, and direct-child rows do not expose a recursive navigation entry. These operations are not marked passed merely because the peer or lower-level APIs can perform them.

### L06 — Sign out strands the app without a sign-in form (high)

During account setup, Account > Sign out produced only `Sign in to open a graph` and Diagnostics. Diagnostics reported Offline / Signed out / Closed. Restarting Debug and then the freshly built Release app reproduced the missing form.

The advisory Keychain entry `com.logseq.journal.local-account-binding` still existed. Backing up and removing only that advisory entry restored the normal sign-in form on the next launch. Existing graph files and cryptographic keys were not removed. This was a test-environment recovery action, not a source repair.

The initial assumption that the existing session belonged to a different account was not established: later authenticated catalog inspection showed the same account identifier. The defect is the observed sign-out/login recovery behavior, not an account-identity assertion.

### L07 — First opening a never-downloaded encrypted graph shows an internal key error (medium)

Selecting the new target graph initially displayed `wrappedGraphKeyUnavailable`, requiring a separate Continue online click before normal download/password entry. No local target mirror existed at that point. Fresh graph download should offer the normal online/unlock flow without presenting an internal storage-error identifier.

After local reset, cached keys were correctly retained and redownload started directly.

### L08 — Capture action controls lack meaningful accessibility labels (medium)

Capture exposed its task-intent and save controls as private-use icon glyphs (``, ``). The selected Todo intent changed the visible button background but did not announce a meaningful selected state in the accessibility tree. This makes the required write controls difficult to discover and operate with assistive technology. Other app controls, such as Account and Diagnostics, had useful labels.

## Coverage boundaries

- There is no accessible standalone search, page browser, date jump, property editor, move/indent/outdent, attachment-open, or recursive detail UI in the inspected native application. Cmd+F did not open search. These are capability gaps, not successful test cases.
- Peer edits and child creation were limited to audit records and used to exercise incoming sync. They do not count as passing native editing/child-creation coverage.
- A briefly malformed test parent/child during peer keyboard automation was corrected through explicit text fields before the isolated child-preview check. No existing user record was involved; it is not claimed as an app defect.
- No offline network interruption or all-device concurrency matrix was executed. API checks on a local copy are not represented as native offline/reconnection validation.
- No bug regression test or implementation change was added. The standalone public-API probe is an audit instrument against a private copy and does not bypass `.mli` boundaries.

## Final verification

After the second recovery, native deletion worked in the healthy graph:

| Final operation | Result |
| --- | --- |
| Delete `task-after-failure` | Accepted through cursor 27, empty outbox; absent on peer |
| Delete `todo-healthy` | Accepted through cursor 28, empty outbox; absent on peer |
| Keep a different parent expanded during deletion | Its direct child remained visible after authoritative incorporation |
| Delete parent and child, then immediately Undo | Both restored, including the expanded child |
| Commit parent/subtree deletion | Parent and child removed locally and on peer |
| Delete Unicode multiline test block | Removed locally and on peer |
| Open empty Capture | No save action for an empty draft |
| Type draft, dismiss, reopen | Draft retained visibly; no graph mutation committed |
| Clear the draft and dismiss | No test input left in Capture |
| Return to picker and reopen target | Existing mirror reopened without download or password entry; timeline readable |
| Settings and Diagnostics | Populated normally; final Current / Ready / Open, zero outbox and payload metrics |
| Overnight date rollover | On the 2026-09-07 recheck, the running app showed the correct September 7 header and retained the empty September 6 journal |

At 2026-09-06 21:44:18, local and independently fetched server checkpoints were
both cursor **30**, checksum **`b354899130018f49`**. The checksum equals the
pre-mutation baseline. SQLite integrity remained `ok`; the outbox was empty.
The later 2026-09-07 local recheck had advanced to cursor **31**, checksum
**`f17dea4506a39ef5`**, with active durable status and an empty outbox. No additional
audit mutation was submitted after cleanup. The actor responsible for that later
transition was not established; the cursor-30 cleanup comparison remains a
timestamped result, not a claim that the graph stopped changing afterward.

Logical before/after comparison found 168,716 datoms in both states and no remaining
test titles. The only changed attribute on an original entity was one
`block/updated-at` value, consistent with editing the containing journal during
the audit. This is not a byte-for-byte restoration claim. All five persisted test
blocks, including the child, were removed through normal native subtree/block
deletion; the peer independently confirmed their absence.

The app is left running on the target timeline. Both failed local queues were
backed up before authorized local resets. The temporary standalone audit ID token
was removed. Recovery backups and redacted evidence remain in the private audit
directory; the user's existing worktree changes remain untouched.

Validation: Release build passed; the public API probe passed; agent decision
validation (`spec-dev-tool check --all`) and `git diff --check` passed. Existing
unit suites were not rerun as a substitute for these live failures.

The requested testing and issue inventory are complete for the native application's
available operation surface. The app does **not** pass the overall functional
acceptance: L01, L02, L04, L05, and L06 are material failures. Unsupported or
unreachable surfaces and untested network scenarios remain explicitly identified
above; no source fixes are included in this audit.
