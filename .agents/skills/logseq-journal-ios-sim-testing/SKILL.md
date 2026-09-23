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
on the iOS simulator wedges the app: the main thread enters a
`PresentationController.nativeVisible` didSet -> `RenderTree.commit` ->
`NativePresentationContent.body` -> `appeared` invalidation loop at ~100% CPU and
the sheet never displays; all subsequent input is dead. Native `Menu`
presentations (e.g. the "..." account menu) do NOT loop.

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

## Devin Secrets Needed

- `LOGSEQ_JOURNAL_USERNAME`, `LOGSEQ_JOURNAL_PASSWORD` — Cognito sign-in
- `LOGSEQ_JOURNAL_E2EE_PASSWORD` — graph encryption unlock

## Other notes

- Taps: screenshots are 1024x768; sim phone content ~x 380-650, y 130-650. Bottom
  toolbar icons: calendar (~415,615), favorites star (~455,615), capture pencil
  (~607,615); "..." account menu top-right (~616,143).
- `%cpu` from `ps` is cumulative since launch — a steady climb to ~100% after a
  timeline load indicates the render loop; an idle healthy timeline sits ~3%.
