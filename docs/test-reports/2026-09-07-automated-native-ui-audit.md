# Native UI automation audit

Run: 2026-09-07 20:38–20:45 Asia/Shanghai (completed at 12:45 UTC).
Automation: computer-use-logseq-journal-app-ui.

## Environment and evidence limits

Computer Use exercised the native Release app at `/Users/rcmerci/gh-repos/logseq_journal/flutter/build/macos/Build/Products/Release/bonsai_flutter_logseq_journal_host.app`, on Lambda-RTC-test. Repository HEAD was `b32baf0`. The binary was not rebuilt and source/binary equivalence was not established. Findings derive from native accessibility observations and screenshots in this task. Earlier findings in `2026-09-07-lambda-rtc-test-macos-retest.md` are historical, not new reproductions.

## Findings sorted by severity

### A01 — P1: Detail and source editing are unreachable

Double-click the newly captured plain record. No navigation or editor appears; the accessibility tree remains unchanged. No alternative detail action is exposed on the row. Consequently detail reading, source editing, child creation, and recursive detail navigation cannot be completed through the tested native surface. The public `Journal_routes.open_detail` exists, but an app-source search found no caller of that function. This matches historical L05. Expected: an accessible entry action opens the detail/editor flow.

### A02 — P2: Capture controls have no meaningful accessible names or task state

Open empty Capture: task intent is announced as the private-use glyph ``. Type a draft: Save is announced as ``. Toggle task intent: accessibility state does not change, although saving produces a Todo. Expected: meaningful action names and selected state. This reproduces historical L08.

### A03 — P2: Reopened draft is visually present but missing from accessibility value

Enter `QA-AUTO-20260907-UI plain 🌱` plus a second line, dismiss, and reopen Capture. The screenshot displays the full retained draft, while a fresh full accessibility tree reports only `text field (settable)` with no value. Saving preserves both lines. This is an accessibility defect, not draft data loss.

### A04 — P2: Initial timeline is absent from the accessibility tree

On initial attachment and again after quit/relaunch, the full tree contains only the window/container and native menu items, while screenshots show the populated timeline and Capture button. Clicking the visible Account button enables populated semantic output. Expected: primary content and controls are accessible immediately after startup. A sparse tree alone must not be described as a blank UI.

## Coverage

| Operation | Result |
| --- | --- |
| Restore most recent graph after quit/relaunch | Passed visually; no graph picker; A04 applies |
| Account open/close | Passed |
| Settings Dense, Comfortable, Balanced | All selected values and typography samples changed; restored Balanced |
| Diagnostics open/close | Passed; initially and after cleanup Current / Ready / Open, outbox zero |
| Empty Capture | No Save exposed |
| Multiline Unicode Capture | Passed; complete native row visible |
| Draft dismiss/reopen | Visually retained; A03 |
| Direct Todo Capture | Passed this run; no fatal duplicate-key UI error |
| Status: Backlog, Todo, Doing, In review, Done, Canceled, Clear | Each selected state verified on test row |
| Swipe right/status picker | Passed |
| Swipe left/delete and immediate Undo | Test row removed and restored, confirmed by full tree |
| Committed test-row deletion | Both test records disappeared and stayed absent after restart |
| Historical scrolling | Additional older entries visible |
| Direct child disclosure | Arrow click displayed direct children and Expanded state |
| Row-wide accessible activation of collapsed item | Did not expand in sampled action; arrow worked; not separately classified without further isolation |
| Graph picker and same-graph reopen | Passed; both test records retained before cleanup |
| Refresh graphs | Click accepted; unchanged catalog, no verified completion signal |
| Cmd+F | No search appeared; capability gap, not an asserted supported-feature regression |
| Detail/edit/child creation | Blocked by A01 |

## Historical issues and remaining scope

Earlier L01 (fatal Todo Capture) and L02 (stuck outgoing queue) did not reproduce in this run. A successful sample does not establish their complete resolution. L03 (stale incoming child preview), L04 (persistent Failed phase), L06 (missing sign-in after sign-out), and L07 (first encrypted-open key error) were not re-executed and remain historical concerns.

Not executed: sign-out/sign-in, local graph-copy deletion/redownload, uncached encryption-key setup, offline/reconnect, independent-peer content verification, concurrency, every graph/data fixture, window-size matrix, or iOS. Local-copy deletion cannot be performed as an unattended permanent deletion without action-time confirmation. Sign-out was left unexecuted to retain the working authenticated session; this is a coverage limitation, not a newly demonstrated failure. No universal all-UI-pass claim is made.

## Cleanup and validation

Only two uniquely prefixed test records were created and modified. Both were deleted through the native UI. Before restart, Diagnostics showed Current / Ready / Open, Outbox records 0 / 4096, Outbox bytes 0 B, Protected payload 0 B, and Origin evidence 0 B. Restart directly restored the graph with both test records absent. No independent peer or byte-for-byte database restoration was claimed. Original records were not edited. No implementation, OCaml spec, Dune, or framework files changed.

`spec-dev-tool --help`, lifecycle discovery, and `spec-dev-tool check --all` were run; document validation passed. This report records observations and makes no implementation decision. No regression tests were added.
