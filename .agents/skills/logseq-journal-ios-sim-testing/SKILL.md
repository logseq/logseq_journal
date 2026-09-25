---
name: logseq-journal-ios-sim-testing
description: End-to-end test the logseq_journal app on the iOS Simulator — adhoc-signed build for working Amplify/keychain auth, E2EE graph unlock flow, inspecting persisted datoms in the mirror SQLite, and the V.Sheet render-loop workaround that otherwise blocks all modal UI on the simulator.
---

# Testing logseq_journal end-to-end on the iOS Simulator

The iOS Simulator exercises the same OCaml runtime as the macOS app and is the most
reliable path when no Apple Development certificate/team is available (the macOS
sandboxed build fails Amplify sign-in with keychain error -34018 without a paid cert).

## Build and install

```bash
eval $(opam env --switch=logseq-journal --set-switch)
bonsai-swiftui build ios --simulator --profile debug
# --simulator builds may embed no keychain entitlements; rebuild adhoc-signed so
# Amplify session persistence and E2EE keychain work:
xcodebuild -project apple/BonsaiLogseqJournal.xcodeproj -scheme BonsaiLogseqJournal-iOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/DerivedData \
  -clonedSourcePackagesDirPath _build/bonsai-swiftui/dependencies/packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
xcrun simctl install booted apple/DerivedData/Build/Products/Debug-iphonesimulator/BonsaiLogseqJournal.app
xcrun simctl launch booted com.example.bonsaiFlutterLogseqJournalHost
```

Lui build path (journal_view.ml / Lui_elements): `JOURNAL_IOS_TEAM_ID=K378MFWK59
dune build @ios-app` → flat bundle `_build/apple/ios-simulator/LogseqJournal.app`,
bundle id `com.logseq.journal`. The bundle embeds a `__TEXT,__entitlements`
section (verify: `otool -l <binary> | grep -A3 entitlements`) so keychain + Amplify
sign-in DO work on the sim even adhoc-signed — the old "sign-in impossible on sim"
note does not apply to this build.

When several simulators are booted, `booted` is ambiguous — always use an
explicit UDID (`xcrun simctl list devices | grep Booted`) for install/launch/
screenshot/get_app_container.

Notes:
- The lock file may be missing the `ocaml-ios64-simulator` pin —
  `bonsai-swiftui build ios` fails with "no matching definition" until you add
  `  "ocaml-ios64-simulator" {= "5.1.1"}` next to the `ocaml-ios64` entry in
  `logseq_journal.opam.locked`.
- iOS toolchain packages live in a separate switch `bonsai-swiftui-ios-simulator`.
  `bonsai-swiftui toolchain install iossimulator` refuses if that switch already
  exists; instead run `opam install -y --switch=bonsai-swiftui-ios-simulator
  bonsai_swiftui_ios_simulator_runtime_sdk bonsai_swiftui_ios_simulator_sdk` then
  `bonsai-swiftui toolchain verify iossimulator`.
- Needs several GiB of free disk (opam toolchains + DerivedData).
- After `simctl install`, the app's data container UUID can change — always resolve
  it fresh: `xcrun simctl get_app_container booted com.example.bonsaiFlutterLogseqJournalHost data`.

## Sign-in and E2EE unlock flow

1. Sign-in sheet auto-presents: enter `${LOGSEQ_JOURNAL_USERNAME}` /
   `${LOGSEQ_JOURNAL_PASSWORD}`.
2. Graph picker lists synced graphs (names may be ciphertext-looking for E2EE graphs —
   match by position/recent). Pick one.
3. First open on a fresh container: `Load_and_unlock_graph_key` fails (keychain miss)
   and the error screen shows a **Retry** button. Tap Retry — this routes to
   `begin_e2ee_key_access` and presents the "Unlock your graph" password prompt.
   Enter `${LOGSEQ_JOURNAL_E2EE_PASSWORD}`.
4. The graph then bootstraps: "Downloading graph" -> snapshot apply -> timeline.
   On later launches the local mirror makes restore instant.
- If a graph stalls at "Downloading graph" with ~0% CPU (all fibers parked —
  `Activate_snapshot` never runs), it will not recover; delete its mirror dir and
  try a different graph. Small/empty graphs bootstrap fastest.

## Inspecting persisted datoms (verifying block/title etc.)

The local mirror is at:

```
<container>/Library/Application Support/logseq-db-worker/synced-graphs/<graph-uuid>/db.sqlite
```

- `kvs` is content-addressed (`addr`, `content`, `addresses` JSON). Local overlay
  transactions store PLAINTEXT transit-encoded datoms; server-mirrored entities
  may appear as E2EE ciphertext (`"~b..."` base64 pairs) — search both.
- Find a journal page: `sqlite3 db.sqlite "select content from kvs where content
  like '%2026-0922%'"` — shows datoms like
  `[203,"~:block/title","Sep 22nd, 2026",...],[203,"~:block/name","sep 22nd, 2026",...]`.
  Deterministic journal-page uuid pattern: `00000001-YYYY-MMDD-0000-000000000000`.
- `sync_outbox` drains to 0 when mutations flush to server;
  `overlay_terminal_batch_receipts` holds `acceptedBatch` receipts with
  `server-cursor` values proving server acknowledgement.

## V.Sheet render-loop bug (critical simulator blocker)

Presenting any `V.Sheet` modal (Capture composer, Diagnostics, error info, status)
on the iOS simulator CAN wedge the app: the main thread enters a
`PresentationController.nativeVisible` didSet -> `RenderTree.commit` ->
`NativePresentationContent.body` -> `appeared` invalidation loop at ~100% CPU and
the sheet never displays; all subsequent input is dead. Native `Menu`
presentations (e.g. the "..." account menu) do NOT loop.

Update (Lui_elements branch, iOS 26.5): the wedge did NOT reproduce — the sheet
presents full-screen at 0% CPU, the editor works, and edge-drag dismiss works
(grab the very top edge ~y148, not the title area). However the sheet's nav
chrome (title + toolbar items Close/Task/Save) does not render inside the
presented sheet — mount ops are emitted correctly; likely an iOS host
limitation. Verify sheet chrome on the macOS app if it matters.

Workaround for testing capture/modal flows — temporarily render modals inline
(`app/application.ml`, where `V.Sheet.create` wraps `modal`):

```ocaml
(match modal with
 | None -> base
 | Some content ->
   let _ = status in
   V.Navigation_stack.create ~title
     ~on_path_change:(Ui.Event.Handler.create (fun _ -> ())) ~path:[] content)
```

This exercises identical reducer/runtime logic; only presentation differs.
Revert before finishing — never merge the patch.

## Two-client sync testing (upload + download + live push)

Boot a second sim device and install the same .app — a real second client exercises
the full bidirectional path:

```bash
xcrun simctl boot <DEVICE2_UDID>          # any second device, e.g. iPhone 17 Pro
xcrun simctl install <DEVICE2_UDID> <app> # install takes ~1-2min on a fresh device
xcrun simctl launch <DEVICE2_UDID> com.example.bonsaiFlutterLogseqJournalHost
# sign in (same account), pick same graph, Retry -> E2EE password -> timeline
```

- A fresh device bootstrapping already proves the download path: the snapshot
  includes all previously synced blocks (timeline shows them after unlock+apply).
- Live push: server sends `Changed{t}` -> client sends `Client.Pull{since}` ->
  `Pull_ok{txs}` -> applied to mirror -> feed auto-refreshes (`Sync_refresh`).
  A captured block on B reached A's mirror kvs + timeline in <10s untouched.
- Reconnect path: `Foreground_changed{foreground=true}` -> `start_websocket` ->
  `websocket_opened` -> `Pull`. Cycle by launching another app on that device
  (e.g. `xcrun simctl launch <dev> com.apple.Preferences`) then relaunching.

### Idle websocket dies with no auto-reconnect (observed sync gap)

An idle-foregrounded app's websocket gets closed ("WebSocket peer EOF" — visible
via the "!" error badge on the timeline -> Error info). `websocket_closed` marks
`sync_phase = Offline` but emits NO reconnect effect while the app stays
foregrounded (`lsof` shows zero TCP sockets). Remote changes stop propagating
until a background->foreground cycle or relaunch. Check socket liveness with
`lsof -nP -p <pid> | grep ESTABLISHED`.

- iOS keyboard slide-to-type intro appears once per fresh device — tap Continue;
  typed text usually still lands in the field.
- Watch disk space: booting a second sim device consumed several GiB; keep
  swiftpm/Xcode-DerivedData caches cleared.
- Use `xcrun simctl io <udid> screenshot out.png` to capture a specific device's
  screen when simulator windows overlap.

## Known dead/inert UI paths (verified — do not misreport as regressions)

- **Timeline/detail row actions are dead-wired.** `V.Native_list.vertical`
  accepts `~on_row_event` but no call site passes it (application.ml ~1310,
  ~1589, ~2261; journal_native_collection.ml ~172). Swipe "Status"/"Delete" and
  context-menu "Change status"/"Delete block and descendants" presses DO reach
  OCaml as `extension_event` (`type="row_event"` payload) but iterate over
  `None` → emit_patch len=0 → the reducer never sees them. Consequences:
  - Swipe-delete LOOKS like it works (Swift extension animates the row away)
    but nothing persists — the row returns on relaunch.
  - "Change status" taps are fully inert; the status sheet (the app's only
    `V.Picker ~style:Inline` → radio_group path) is therefore unreachable via UI.
  - Verified identical in the pre-refactor tree — pre-existing gap, not a
    regression. To fix: wire a `~on_row_event` handler that decodes
    `{"key":"status:<uuid>"|"delete:<uuid>","row":"block:<uuid>"}` into the
    `timeline-status:`/`timeline-delete:`/`detail-delete:` action strings.
- **Composer "Task" toggle is invisible.** `composer-task` (a `V.toggle
  ~style:Button` in a Primary_action toolbar item) emits correctly (checked,
  accessibility-label, width=40) but `set_leaf_label` cannot write an icon —
  `Lui_protocol` does not support InlineIconName on kind `toggle` — so the
  icon-only collapse yields an empty 40pt cell. Pre-existing; toggle is still
  mounted/functional.

## Debugging the lui emit/event pipeline (lui build path)

`app/journal_lui_bridge.c` is the C boundary. Temporary fprintf probes that
proved events reach OCaml and showed exact patch ops (revert after use):

```c
// in emit_patch (after caml_copy_string of the json):
fprintf(stderr, "[PATCH-DBG] %s len=%d: %s\n", tag, (int)caml_string_length(json), String_val(json));
// in journal_ocaml_extension_event (top of fn):
fprintf(stderr, "[EVT-DBG] extension_event node=%d name=%s payload=%s\n", node, name, payload);
```

Console via `xcrun simctl launch --console-pty <udid> com.logseq.journal > log 2>&1`
(stderr is the only diag channel). `git checkout` the file to revert.

## Devin Secrets Needed

- `LOGSEQ_JOURNAL_USERNAME`, `LOGSEQ_JOURNAL_PASSWORD` — Cognito sign-in
- `LOGSEQ_JOURNAL_E2EE_PASSWORD` — graph encryption unlock

## Other notes

- Taps: screenshots are 1024x768; sim phone content ~x 380-650, y 130-650. Bottom
  toolbar icons: calendar (~415,615), favorites star (~455,615), capture pencil
  (~607,615); "..." account menu top-right (~616,143).
- `%cpu` from `ps` is cumulative since launch — a steady climb to ~100% after a
  timeline load indicates the render loop; an idle healthy timeline sits ~3%.
