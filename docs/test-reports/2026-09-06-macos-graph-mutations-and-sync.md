# macOS Graph Mutation and Sync Test Report

## Environment and scope

- Date: 2026-09-06, approximately 13:49–14:09 Asia/Shanghai.
- OS: macOS 26.6.2 (25G83), arm64.
- Source: worktree based on `7a6fcae`, including the existing staged and unstaged changes.
- Build: `opam exec -- bonsai-flutter build macos --profile=debug` succeeded.
- App: `flutter/build/macos/Build/Products/Debug/bonsai_flutter_logseq_journal_host.app`.
- Graph: `ocaml-sync-test`, `b49df932-9915-468d-a190-8f769d40ff0b`.
- Independent peer: the existing authenticated `https://app.logseq.com/` Chrome tab on the same graph.
- Mutations were limited to records created for this test, using the `QA-20260906-1352` prefix. Existing user records were not edited or deleted.
- UI interactions used the actual macOS app. Read-only SQLite observations supplemented UI and peer checks. Unit tests were not treated as proof of deployed sync.
- No implementation, spec, or dune files were edited during this audit.

## Result

Sync is only partially functional. Initial capture and status changes reached the peer. Incoming changes reached local storage but did not refresh the running timeline. After an app restart, a deletion reached the peer but remained submitted locally; later writes stayed queued across further restarts.

The application mutation surface contains Capture, Update_source, Create_child, Set_task_state, and Delete_subtree. Capture, status, and delete were exercised through the UI. Update_source, Create_child, and the detail task toggle could not be exercised from macOS because the detail route has no reachable UI entry.

## Coverage matrix

| Operation | Actual result | Sync evidence |
| --- | --- | --- |
| Unlock existing encrypted graph | Initial launch exposed `wrappedGraphKeyUnavailable`; Continue online reached password entry; user unlocked successfully | Ready / Open / Current; later launches reopened the same graph without another password prompt |
| Capture plain ASCII block | Passed; complete marker saved | Marker appeared in the peer journal |
| Capture Todo with rapid ASCII input | Passed; all digits and alphabet characters survived and Todo was applied | Peer displayed the complete task and task icon |
| Set Backlog | First attempt failed with a revision conflict; identical retry passed | Peer displayed the Backlog icon |
| Set Todo | Passed after the Backlog retry | Local status updated; peer task icon and subsequent accepted status changes observed |
| Set Doing | Passed | Peer displayed Doing icon |
| Set In review | Passed | Peer displayed In Review icon |
| Set Done | Passed | Peer displayed checked Done icon |
| Set Canceled | Passed | Peer displayed Canceled icon |
| Clear status | Passed | Peer removed the status icon |
| Edit block in macOS detail | Blocked: no detail entry | Not verified |
| Add child in macOS detail | Blocked: no detail entry | Not verified |
| Toggle task in macOS detail | Blocked: no detail entry | Not verified |
| Edit test block from peer | Peer edit saved | Local SQLite contained the edited marker, but running macOS timeline stayed stale; restart displayed it |
| Add child from peer | Peer child saved under the test parent | Local SQLite contained the child marker, but running timeline stayed stale; restart displayed it |
| Expand/collapse children | Initially passed after restart | An unrelated committed deletion subsequently cleared visible children until collapse/expand |
| Delete task then Undo | Passed; task restored | Peer retained task; no delete was committed during the undo window |
| Delete task after undo window | Failed twice before restart; passed locally after restart | Peer removed task after restart, but local outbox never acknowledged this deletion |
| Delete parent and child, then Undo | Passed; both restored locally | Peer retained the subtree |
| Commit parent-and-child deletion | Local subtree disappeared | Delete remained queued; peer still retained parent and child |
| Paste into Capture | Failed: pasted content was not retained by the application | A saved block contained only the text that preceded paste; its insert was subsequently queued behind the stuck deletion |
| Dismiss Capture | No graph write from the dismissed draft; draft retained on reopening | Draft cleared by process restart |
| Restart with pending writes | Pending writes survived locally | Submitted/queued state did not recover during this session |
| Diagnostics admission metrics | Failed: all four fields stayed Loading | Direct SQLite inspection could read the real outbox count |

## Issues

### M01 — Incoming sync does not refresh the running timeline (high)

1. Create `QA-20260906-1352 plain alpha` in macOS and wait until it appears on the peer.
2. In the peer, rename it to `QA-20260906-1352 edited-from-web` and add `QA-20260906-1352 child-from-web` as its child.
3. Revisit the macOS timeline and Diagnostics.

Actual: the timeline retained `plain alpha` and had no child disclosure. Diagnostics reported Current / Ready / Open. Read-only SQLite observations showed the server cursor advancing to 498 and the new title/child strings present in KVS storage. An app restart immediately displayed the new title and child. This establishes a live presentation/update failure; storage substring checks alone were not used as proof of the logical current view.

Expected: incoming committed changes update visible blocks and their child structure without restarting.

### M02 — A submitted deletion blocks subsequent sync across restarts (high)

After restarting to refresh the graph, delete the test Todo, then delete the test parent subtree after the first undo window has completed.

Actual: the peer removed the Todo, but the application remained Submitting. The first delete stayed submitted and the subtree delete stayed queued. A later Capture insert also stayed queued. Restarting preserved the queue without clearing it. The peer retained the parent and child, and never displayed the later Capture marker during the observation window.

At 14:01:37 and 14:06:10, the applied server cursor was still 498. At 14:06:10 the queue contained:

| Position | Mutation | State | Attempts | Submission base |
| --- | --- | --- | --- | --- |
| 0 | deleteBlocks | submitted, `submission-batch:v1:2` | 1 | `server-cursor:v1:498` |
| 1 | deleteBlocks | queued | 0 | none |
| 2 | insertBlocks | queued | 0 | none |

The submitted record had no observed origin cursor. The transport/acknowledgement root cause was not established by this audit. Redacted evidence is saved locally at `/tmp/logseq-journal-macos-qa-20260906/sync-evidence.json`.

The final check at 14:08:48 showed Failed / Ready / Open in Diagnostics, with the same three outbox records and cursor 498. The timeline did not expose an Error info button or a retry action for this sync failure. The final evidence is `/tmp/logseq-journal-macos-qa-20260906/sync-evidence-final.json`.

### M03 — Stale mutation preconditions cause false conflicts and repeated deletion failure (high)

The first Backlog change on the newly captured, already uploaded plain block failed with:

> Unable to change status: Status changed elsewhere. Try again.

No peer edit of that block had occurred. Repeating the same action succeeded.

A newly captured Todo then failed deletion twice, despite that Todo never being edited on the peer. The row first disappeared during the undo window and then returned. Error info showed `unsupportedSemantics`, operation `deleteSubtree`, and `The mutation precondition did not match.` Restarting refreshed the graph and allowed the delete to reach the peer, though M02 then prevented local acknowledgement.

The stale visible title in M01 and these stale mutation preconditions may share a missing refresh path, but that relationship is not proven here.

### M04 — Detail editing, child creation, and detail task toggle are unreachable (high)

Clicking the test block text through accessibility and clicking its visible row did not open a detail page. Rows without children exposed static text; rows with children offered only expansion/collapse. No edit or add-child action was available in the tested UI.

Source inspection corroborated the runtime result: `Journal_routes.open_detail` is declared and implemented, but has no caller in `app/`. Detail handlers exist but are not reachable from the timeline.

Relevant source: `app/journal_routes.ml`, `app/journal_row.ml`, `app/journal_timeline.ml`, `app/application.ml`.

### M05 — Capture drops pasted text and diverges from native accessibility state (high)

1. Type `QA-20260906-1352 unicode ` in Capture.
2. Paste a multiline string containing Chinese text and an emoji.
3. Observe the field and save.

Actual: accessibility briefly included the pasted suffix, but the rendered field and saved block contained only the original prefix. The saved suffix was absent.

A separate native TextEdit control accepted the same Unicode paste. A second test copied known test text from TextEdit with Cmd+C and pasted into a focused Capture field with Cmd+V. Accessibility again briefly contained the pasted text; typing `END` afterward continued from the old text, discarding the pasted content. This also occurred using the real clipboard, not only the automation paste helper.

The automated `typeText` method itself omitted non-ASCII characters in both TextEdit and Journal, so non-ASCII simulated keystrokes are excluded from the app defect claim. Rapid ASCII typing and ASCII newlines worked. The existing exploring decision `docs/agent-guide/exploring/bugfix/2026-09-05-accept-rapid-controlled-text-input-edits.md` documents a relevant controlled-input revision risk, but this audit did not prove the exact callback ordering for paste.

### M06 — Overlay DB diagnostics never finish loading (medium)

Open Account > Diagnostics after a graph is Ready / Open. Outbox records, Outbox bytes, Protected payload, and Origin evidence all show Loading indefinitely. Reopening Diagnostics and restarting the process did not fix this during the test. The same screen showed Loading both when SQLite outbox count was zero and when three writes were pending.

This prevents the UI from exposing the queue evidence needed to understand M02.

### M07 — Committing an unrelated delete hides expanded children (medium)

1. After restarting, expand the test parent and verify its child is visible.
2. Delete the separate test Todo and allow the undo timer to complete.
3. Observe the parent.

Actual: the parent remained marked Expanded, but its child vanished from the timeline. The peer still retained the child. Collapsing the parent displayed the child preview, and expanding it again restored the child row.

Expected: refreshing the page after an unrelated deletion preserves or reloads expanded children.

## Existing problems and coverage limits

- The old process was initially Failed / Restoring local / Closed. The freshly built version correctly exposed `wrappedGraphKeyUnavailable` and Continue online, allowing user-assisted recovery. The old process's infinite restore behavior is not counted as a failure of the new build.
- The initial missing wrapped key is consistent with the previously recorded local-reset defect, but this audit did not invoke Reset local copy. The existing reset investigation remains in `docs/agent-guide/exploring/bugfix/2026-09-05-complete-delete-and-redownload-lifecycle.md`.
- Offline writing/reconnection, a cold download, and creation of a previously absent journal day were not tested. The live sync queue was already stuck, so those behaviors cannot be claimed to pass.
- There are no standalone page rename, property editor, move, indent, or outdent actions in the current macOS mutation UI inspected here. Peer-side indentation was used only to prepare the subtree test.
- The opt-in deployed worker E2E was not run: its required credential environment variables were absent. The authenticated app and browser were used for actual sync tests instead.

## Supplemental validation

- macOS Debug build: passed.
- `dune exec test/logseq_db_worker_application_integration_test.exe`: 13 tests passed.
- `dune exec test/journal_routes_test.exe`: passed.
- `dune exec test/journal_timeline_state_test.exe`: passed.
- `spec-dev-tool check --all`: passed.

These passing tests did not catch the live UI and sync failures above.

## State left for follow-up

- The latest Debug app is running with the same selected encrypted graph.
- The temporary input draft was cleared by restarting.
- The test Todo is absent on the peer; its delete remains unacknowledged locally.
- The test parent and child remain on the peer, while their local delete is queued.
- The local `QA-20260906-1352 unicode ` block remains with a queued insert.
- The queue was preserved as evidence. Cleanup is incomplete because sync is blocked; no pre-existing user data was changed.
- The TextEdit control document was closed and moved from the save dialog's colon-encoded filename to `/tmp/logseq-journal-macos-qa-20260906/input-control.rtf`.
