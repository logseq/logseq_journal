# Native UI automation audit

Run: 2026-09-08, approximately 13:22–13:35 Asia/Shanghai; login recovery pending at report creation.
Automation: computer-use-logseq-journal-app-ui.

## Environment and scope

Computer Use exercised `/Users/rcmerci/gh-repos/logseq_journal/flutter/build/macos/Build/Products/Release/bonsai_flutter_logseq_journal_host.app`, Lambda-RTC-test and ocaml-sync-test. An existing Chrome Logseq tab on Lambda-RTC-test provided an independent peer. Repository HEAD was b32baf0 with pre-existing uncommitted changes. The app was not rebuilt; source/binary equivalence was not established. Findings apply to the observed installed binary, not a verified build of the current checkout. Earlier unattended attempt was blocked by macOS lock; this run resumed after the user unlocked it.

## Findings sorted by severity

### B01 — P1: Deleting a parent with an incoming child strands the timeline on Opening journal

Create a native multiline parent, add a child through the web peer, and update that child. In the native timeline, swipe the parent left and select Delete block and all descendants. The timeline is replaced by Opening journal and only Diagnostics remains usable. It persists across diagnostic open/close and subsequent observations. Diagnostics reports Current / Ready / Open and zero outbox. On the first attempt no Undo was captured; after quit/relaunch, the parent and child are still present. Repeating after restart again enters Opening journal. A removal toast and Undo briefly appeared on that attempt, but the tool could not activate the rapidly invalidated Undo element; successful Undo is not claimed. Incoming deletion of the parent through the peer also led to Opening journal. Restart restored the timeline after peer cleanup.

Impact: a normal deletion flow makes the journal unusable until restart, with misleading healthy diagnostics. First-attempt deletion did not persist. The precise ownership and root cause were not investigated. Do not generalize to every deletion: a no-child Todo disappeared locally immediately, although complete native deletion/Undo semantics were not independently established while the peer editor was open.

### B02 — P1: Detail, source editing, and child creation remain unreachable

Double-click a newly created plain record; the tree and view remain unchanged. Right-click also exposes no detail/editor menu. No accessible alternative detail action is exposed. Detail reading, source editing, native child creation, and recursive detail navigation therefore remain blocked on the tested surface. This reproduces prior A01; no current-source root-cause claim is made.

### B03 — P2: Collapsed child preview stays stale after incoming edits

The web peer creates a child under the native test parent, then updates its text to `QA-AUTO-20260908-UI child incoming v2`. The native collapsed preview retains the child's initial intermediate text. Diagnostics reports Current and an empty outbox. Expanding the parent displays the correct v2 direct child; collapsing again restores the old preview. Restart refreshes the preview to v2. This isolates a visible collapsed/expanded inconsistency without claiming data loss. Parent text was corrected during fixture preparation and verified on both sides before this comparison.

### B04 — P2: Capture controls expose glyphs instead of names and task state

Empty Capture exposes the task control as ``. With text, Save is ``. Toggling task intent produces no accessibility-tree state change, while saving correctly creates a Todo. Meaningful names and selected state are missing. Reproduces A02.

### B05 — P2: Reopened draft has no accessible value

Enter a multiline Unicode draft, dismiss, and reopen. The screenshot contains the complete draft, but a fresh full tree reports only an unnamed text field without its value. Save preserves both lines. This is an accessibility defect, not loss of the draft. Reproduces A03.

### B06 — P2: Initial and restarted timeline content is absent from accessibility

On initial attachment and repeated quit/relaunch, the tree contains only the native window/container/menu, while screenshots show the populated timeline and Capture. Clicking Account activates the semantic tree. Reproduces A04. Initial attachment also showed yesterday's date until interaction; date rollover was not independently isolated as another defect.

### B07 — P2: Encrypted graph opening exposes an internal error and has no cancel route

Switch to ocaml-sync-test. The app first shows `wrappedGraphKeyUnavailable` and Continue online. Continue online eventually reaches the encryption-password form. That form has no cancel, back, or graph-switch control in the screenshot or full tree, and Escape has no effect. The user supplied the encryption password; submitting it successfully opened the graph. This is a recoverable first-open error and a missing navigation escape, not a permanent restoration failure. No password is stored in this report or automation memory.

### B08 — P2: Accessible parent-row activation does not expand or collapse children

In ocaml-sync-test, activate the row exposed as a button with Value: Collapsed. Nothing changes. Clicking its visible right-edge arrow expands the children. Activating the expanded row through its accessible element again does nothing; the arrow collapses it. The accessible target and actual activation region disagree. Coordinate arrow operation passes.

### B09 — P2: Sign-in fields lack accessible names

After Sign out, the actual login form appears with visible Username and Password labels. Its full accessibility tree exposes two unnamed text fields, Sign In, and Forgot your password?. The fields cannot be distinguished by their accessible names. Login requires user participation; the encryption password was not treated as an account password.

## Coverage and outcomes

| Operation | Outcome |
| --- | --- |
| Restore last graph on repeated relaunch | Passed visually; no graph picker; B06 |
| Account open/close | Passed |
| Typography Dense / Comfortable / Balanced | Values and samples changed; Balanced restored |
| Diagnostics open/close | Passed; Current / Ready / Open, zero outbox sampled after writes |
| Empty Capture | No Save exposed |
| Multiline Unicode draft / dismiss / reopen / save | Content retained and saved; B04/B05 |
| Direct Todo Capture | Passed; no historical fatal Todo error |
| Backlog / Todo / Doing / In review / Done / Canceled / Clear | All seven resulting states verified |
| Right swipe / status picker | Passed |
| Detail/editor / native child creation | Blocked by B02 |
| Parent arrow expand/collapse | Passed; row activation B08 |
| Graph list / refresh | List available; refresh accepted, unchanged catalog not proof of refresh completion |
| Switch to encrypted graph / Continue online / unlock | Opened successfully after user supplied password; B07 |
| Return to Lambda-RTC-test | Passed; both records retained |
| Native capture to independent web peer | Both native records visible in peer |
| Peer child create/update to native | Expanded child updated; collapsed preview B03 |
| Parent delete and descendants | B01, repeated; peer cleanup used |
| No-child Todo delete | Removed locally; Undo activation unverified due invalidated element |
| Sign out | Login form appeared; historical missing-sign-in concern did not reproduce |
| Sign in | Awaiting user manual login |

Not executed: permanent local-copy deletion/redownload, password-reset submission, offline/network setting changes, systematic concurrent-edit scenarios, all graphs and window sizes, iOS. Permanent local deletion needs action-time confirmation. No universal all-UI-pass claim is made.

## Cleanup, limitations, and repository checks

Two root records and one child with the QA-AUTO-20260908-UI prefix were created. Native parent deletion could not complete reliably, so the peer's normal Delete selected blocks flow cleaned the parent/child and remaining Todo. Both the web page and restarted native timeline were observed without all three test records. Original records were not edited. The peer remains on the current journal page. App is on its sign-in form pending manual login. Balanced is restored; the encrypted graph's key cache may have been populated by successful unlocking.

No implementation, tests, OCaml spec, Dune, or framework files were edited by this audit. `spec-dev-tool --help`, lifecycle discovery, and `spec-dev-tool check --all` were run. Check failed because the pre-existing exploring document `docs/agent-guide/exploring/simplification/2026-09-08-shared-apple-local-account-binding-store.md` lacks Proposal and Questions sections. That unrelated document was left untouched. This report records UI evidence and does not make an implementation decision.
