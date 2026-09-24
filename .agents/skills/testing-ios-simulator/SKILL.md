---
name: testing-ios-simulator
description: How to build, sign, install, and drive the logseq_journal iOS app on the iOS Simulator for end-to-end testing, including fixture files for the fileImporter picker and common environment pitfalls.
---

# Testing logseq_journal on the iOS Simulator

## Build environment (lui stack, branch devin/lui-migration)

- OCaml switch: `eval "$(opam env --switch=5.5.0 --set-switch)"` (or `logseq-journal` — check `opam switch list`).
- The lui checkout must exist at `~/repos/lui` (blueprint clones it; swift/Package.swift reads `JOURNAL_LUI_PACKAGE_PATH`, default `../../lui/platform/apple`).
- Build the .app: `dune build @ios-app` — it runs
  `vtool -set-build-version 7 <minos> <sdk> -replace -output journal_complete_iossim.o native_embed.exe.o`
  then `tool/build_journal_apple.sh ios-simulator` → `_build/apple/ios-simulator/LogseqJournal.app`.
- Producing the sim complete object manually (equivalent to what @ios-app does):
  1. `export JOURNAL_APPLE_SDK_ROOT=$(xcrun --show-sdk-path); dune build app/native_embed.exe.o` (macOS object)
  2. `vtool -set-build-version 7 26.0 26.5 -replace -output journal_complete_iossim.o _build/default/app/native_embed.exe.o` (platform 7 = IOSSIMULATOR)
  3. `JOURNAL_OCAML_OBJECT=$PWD/_build/default/app/journal_complete_iossim.o tool/build_journal_apple.sh ios-simulator`
- A "proper" cross-link with the target toolchain's ocamlopt is NOT currently feasible: target `ld` rejects host-built `.cmx` ("building for iOS Simulator, but linking in object file built for macOS"). The vtool restamp of the merged macOS complete object works because it is a single `ld -r` object.
- iOS-sim OCaml toolchain provisioning: `LG_IOS_DEPLOYMENT_TARGET=26.0 ac_cv_func_pipe2=no ac_cv_func_dup3=no ac_cv_func_shmat=no ~/repos/lg/scripts/lg-mobile setup ios simulator` — the `ac_cv_*` overrides are REQUIRED: configure's link-check finds `pipe2`/`dup3`/`shmat` in libSystem.tbd but iOS headers don't declare them, and without the overrides crossopt fails in `pipe_unix.c`.
- `journal_lui_bridge.o` inside `_build/default/app/` is only a compile check — safe to ignore.

## Signing / entitlements (iOS 26.5+ simulator — verified 26.5 AND 27.0)

- **Any `codesign --entitlements` blob makes the binary fail to exec on the iOS 27.0 sim** — `simctl launch` reports "No such process" / "Launchd job spawn failed". Verified with: the build script's expanded `keychain-access-groups=[com.logseq.journal]`, a `FAKETEAMID.`-prefixed variant with `application-identifier`, and even `get-task-allow` alone — ALL fail at exec. Only linker-signed (no entitlements) or plain-adhoc (`codesign --sign -` without `--entitlements`) binaries launch.
- Launchable recipe: flat .app = `Info.plist` + raw swift product `swift/.build/arm64-apple-ios-simulator/debug/JournalApp`, NO codesign. iOS bundles are flat — a stray `Contents/` dir makes `simctl install` fail with "Missing bundle ID".
- **SOLVED — embedded entitlements**: the sim reads entitlements from the `__TEXT,__entitlements` section, NOT the code signature (signature-carried entitlements are validated as *macOS* entitlements and get the exec killed, error 163 — that was the old "no entitlement-bearing binary can exec" trap). `tool/build_journal_apple.sh ios-simulator` now passes `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements` (like Xcode) with `application-identifier` + `keychain-access-groups`, then signs plain-adhoc. Result: `dune build @ios-app` produces a launchable binary whose keychain WORKS — Amplify sign-in, `localAccount`, E2EE graph-key storage all succeed with NO Apple certificate. DEVELOPMENT_TEAM default baked in is `K378MFWK59` (override with `JOURNAL_IOS_TEAM_ID`; the value is also baked into the section so it does not need a matching signature).
- A signing identity still helps for real-device runs: an Apple Development cert was installed for dev@logseq.com (Logseq Inc., team K378MFWK59) — `security find-identity` lists it.
- macOS app caveats: (a) `config/entitlements/macos-debug-profile.entitlements` historically shipped literal `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` — killed at exec (Killed:9, error 163). (b) Plain-adhoc macOS builds DO reach the sign-in dialog (generic-password reads to the app's own group work), but Amplify sign-in still fails -34018 for its access-group keychain ops; re-signing adhoc WITH `keychain-access-groups=[com.logseq.journal]` → AMFI spawn kill (error 163). No signing identity exists on the box → Cognito sign-in cannot complete on macOS either.
- Startup wakeup storm (observed on iOS): ~25-30k `wakeup` callbacks in the first ~40s (~700/s) — OCaml cross-thread pump enqueue floods the MainActor task queue; the first `platformRequest` delivery waits behind the flood (~25s delay), then the system settles to 0% CPU. Not fatal, but adds startup latency and floods instrumented logs.
- **Dead-end-on-all-failures signature (post-5676639)**: with `journal_ocaml_platform_failure` delivering Errors, OCaml's `managed_startup` ignores them (`Error _ -> Effect.ignore`), so `Reconcile_authenticated_user` never reaches the graph_service → `state.manager = None` → the root emits `timeline_page` with an INCOMPLETE tree → the `journal-chrome` extensions get fewer children than their guards require (`JournalChrome.View` renders `EmptyView` unless childIDs.count==3 for `feedback` / ==4 for `journal`) → whole subtree invisible → **blank screen that is a settled dead-end, not a hang** (idle process, no pending continuations). Diagnose by logging patch heads in `JournalRuntime.apply` and counting `insert-child` ops per extension id vs the guard counts in `JournalChrome.swift:91-123`.

## LUI runtime gotchas (found 2026-09-23, golden path verified)

- **Worker→UI wakeup deadlock (iOS)**: an OCaml `Condition` waiter thread calling `deliver` deadlocks — on wake it holds the shared output mutex while re-acquiring its domain lock, which the UI thread holds parked in CFRunLoop. Fix is `Worker.Private.set_output_wakeup`: the wakeup hook runs on the *producing* domain and hops straight onto the UI pump. Same class of bug as the earlier STW starvation — never block a host-domain systhread inside the worker mailbox path.
- **Full-remount render loop**: `Lui_elements.dyn`'s switch uses `equal=(fun _ _ -> false)` — EVERY publish remounts the entire tree (~30+ node ids/cycle). Mount-time emitters feed it: fresh `SecureField`/`Input` fire `TextChanged("")`, `journal-asset-settings` fires its `.task` `deliver()` on each mount, and naive reducers that rebuild identical records keep it alive (~10Hz, 100% CPU). Defenses now in place — `Signal.cutoff ( == )` on the model signal, `Editor.apply_text_edit` returns `None` for identical documents, `days:` extension handler gated by `!asset_settings <> Some settings`, e2ee `Text_edit` guarded by `==`. If a new mount-echo emitter appears, the same dedup pattern applies at the reducer.
- **`V.empty ()` mounts NOTHING (returns node 0)** — extension children are positional on the native side. `journal-chrome` Swift view requires exactly 3 children for `mode:feedback` and 4 for `mode:journal`; an "absent" slot must still mount a real (zero-size) node — `V.column []`/`V.column [x]` placeholders — or `childIDs.count` collapses and the host renders `EmptyView` (blank screen, zero errors).
- **`list-item` rows are inert without `press-enabled`** — `Navigation_link` must set `Lui_protocol.PressEnabled` (and mount the label as a child: `list-item` requires text or children, else the backend fatals).
- **Property-value vocabularies are small**: `RoleValue` accepts only `treeitem|navigation|navigation-heading` (NOT toolbar placements like `bottom_bar`); `VariantValue` only `default|primary|secondary|outline|ghost|destructive` (`plain`→`ghost`, `prominent`→`primary`). Unsupported values throw in `set_prop` during emit.
- **Emit errors were swallowed**: `emit_patch` in `journal_lui_bridge.c` returns 0 on exception → partial op stream → silently blank screens. To diagnose schema violations, add `caml_format_exception(Extract_exception(result))` print there and run a lui build with detailed `set_prop`/`insert_child` messages (local lui branch `devin/set-prop-error-detail` has them: kind/property/value and parent/child kinds — candidate for upstream PR).
- **Extension `standardChildren` must match actual children**: `journal-media`/`journal-list` mount standard children, so `standard_children=true` + the `children` extension-kind whitelist must stay in sync across `journal_lui_native.ml`, `JournalExtensions.swift`, and `journal_extension_registry.dart` (fingerprint mismatch → `unsupported child kind` at emit).
- **Password entry races**: typing into a remount-per-publish field loses focus / stale `''` echo can wipe it. Paste instead: `printf '%s' "$PW" | pbcopy && xcrun simctl pbsync host <udid>`, click field, `cmd+v`.
- **V.Sheet modal presentation freezes on the iOS sim** (menu open + sheet present → stuck overlay, 0% CPU, input dead; same hazard class as the old bonsai render loop). Workaround for sim-only modal testing: render `modal` content inline (`V.column [base; V.Navigation_stack.create ...]` in `application.ml`'s sheet wrapper) — reducer paths are identical. NEVER commit the patch.

## Install / launch / record / diagnose

- `xcrun simctl install <udid> <app>`; `xcrun simctl launch <udid> com.logseq.journal`.
- stderr capture: `xcrun simctl launch --console-pty <udid> com.logseq.journal > console.log` — the app writes no os_log output of its own; stdout/stderr is the only channel. `xcrun simctl launch` accepts trailing `KEY=VALUE` env pairs (e.g. `OCAMLRUNPARAM=v`).
- `open -a Simulator` shows the window; `xcrun simctl io <udid> recordVideo out.mov` (SIGINT to stop); `xcrun simctl io <udid> screenshot out.png`.
- Parked-app signature: `ps -o %cpu` ≈ 0 steady; `sample <pid>` shows the OCaml worker domain in `domain_thread_func → camlIomux__Poll$poll_689 → caml_iomux_poll → poll()` with only a unix socket + self-pipe in `lsof` and no TCP — the app is idle-waiting, not computing.
- LJP2 traffic instrumentation (temporary edits): `JournalRuntime.swift` `platformRequest`/`wakeup` closures and `JournalApplicationPlatform.request`/`services.response` — `FileHandle.standardError.write("[LJP2-DBG] ...")` at each boundary shows whether OCaml issues requests and whether responses return.
- After `simctl install`, resolve the data container fresh via `xcrun simctl get_app_container <udid> com.logseq.journal data` — app-created files (worker dirs, sqlite) appear under `Library/Application Support`; an empty container means the worker never reached storage.
- `%cpu` is cumulative: steady ~100% = render loop; ~3% or less = idle.

## Seeding files for the fileImporter (Files picker)

`simctl` has no file push. Write files directly into the "On My iPhone" local file-provider storage:

```
UDID=<booted-sim-udid>
# find the group container: plutil -p <group>/.com.apple.mobile_container_manager.metadata.plist | grep MCMMetadataIdentifier
# local storage = "group.com.apple.FileProvider.LocalStorage"
cp fixture.png "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Shared/AppGroup/<LocalStorage-UUID>/File Provider Storage/"
```

It then appears under Browse → "On My iPhone" in the fileImporter picker.

## Sign-in / graph unlock

- Sign-in secrets: `LOGSEQ_JOURNAL_USERNAME`, `LOGSEQ_JOURNAL_PASSWORD` (Cognito), `LOGSEQ_JOURNAL_E2EE_PASSWORD` (graph unlock). Type into Username/Password fields via computer-use `type` with `${VAR}` references.
- An occasional transient "wrappedGraphKeyUnavailable" on first graph open is retried successfully by tapping Retry.
- UI landmarks: detail toolbar paperclip = "Attach file" (journal-asset-import); ellipsis.circle on the detail-root media group = "Attachment actions" (journal-media-actions) with "Replace file…"/"Reuse existing…"; account person icon on Journals root → "Attachment settings" sheet (Recent journal days stepper, uploads list).
- Tap precision: document-picker files select via the icon/thumbnail, not the name label; journal rows navigate via tapping the row's ">" area.

## Known environment traps

- Multiple install/uninstall cycles can leave launchd app records stale — a fresh `xcrun simctl shutdown`+`boot` (or `erase`) clears it; don't confuse this with a bad binary.
- `xcrun simctl spawn <udid> log show --predicate 'process == "JournalApp"'` shows only UIKit-internal messages for this app — its own diagnostics go to stderr only.
- Booting a second simulator device while another app's launchd state is confused can surface "denied by service delegate (SBMainWorkspace)" — retry once SpringBoard is fully up.

## Devin Secrets Needed

- `LOGSEQ_JOURNAL_USERNAME`, `LOGSEQ_JOURNAL_PASSWORD`, `LOGSEQ_JOURNAL_E2EE_PASSWORD`
