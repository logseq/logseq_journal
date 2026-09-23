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

## Signing / entitlements (iOS 27.x simulator!)

- **Any `codesign --entitlements` blob makes the binary fail to exec on the iOS 27.0 sim** — `simctl launch` reports "No such process" / "Launchd job spawn failed". Verified with: the build script's expanded `keychain-access-groups=[com.logseq.journal]`, a `FAKETEAMID.`-prefixed variant with `application-identifier`, and even `get-task-allow` alone — ALL fail at exec. Only linker-signed (no entitlements) or plain-adhoc (`codesign --sign -` without `--entitlements`) binaries launch.
- Launchable recipe: flat .app = `Info.plist` + raw swift product `swift/.build/arm64-apple-ios-simulator/debug/JournalApp`, NO codesign. iOS bundles are flat — a stray `Contents/` dir makes `simctl install` fail with "Missing bundle ID".
- Consequence: the launchable build carries NO keychain-access-groups → Amplify keychain access (-34018 class) may fail. On older iOS sims this may differ — if keychain is needed, try `application-identifier=FAKETEAMID.<bundle-id>` + `keychain-access-groups=[FAKETEAMID.<bundle-id>]` (the bonsai .xcent shape), but expect exec failure on iOS 27.
- macOS app caveat: `config/entitlements/macos-debug-profile.entitlements` ships literal `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` — the signed macOS app is killed at exec (Killed:9, `open` error 163, `spctl` rejects). Re-sign with `com.apple.security.cs.allow-jit` + `com.apple.security.network.server` (and drop or properly expand the keychain group) to make it launchable: `codesign --force --sign - --timestamp=none --entitlements <fixed.plist> _build/apple/macos/LogseqJournal.app`.

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
