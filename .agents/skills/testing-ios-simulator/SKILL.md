---
name: testing-ios-simulator
description: How to build, sign, install, and drive the logseq_journal iOS app on the iOS Simulator for end-to-end testing, including fixture files for the fileImporter picker and common environment pitfalls.
---

# Testing logseq_journal on the iOS Simulator

## Build environment

- The `bonsai-ui` opam switch (`eval $(opam env --switch=bonsai-ui --set-switch)`) already has most deps; the blueprint's `logseq-journal` switch may be bare. `opam install --deps-only --with-test --dry-run .` shows what's missing; typically only `bonsai_swiftui`, `bonsai_swiftui_test`, `bonsai_swiftui_tool`, `eio_main`.
- `bonsai-swiftui` CLI comes from `bonsai_swiftui_tool` (opam), repo `~/repos/bonsai-ui` must be at the pinned rev (check `bonsai-swiftui.sexp` / blueprint).
- If `bonsai-swiftui build ios --simulator` fails with "The iOS Simulator switch ... is incomplete: missing dune": run `bonsai-swiftui toolchain install iossimulator` (~15-25 min, installs ~240 cross pkgs into `~/.opam/bonsai-swiftui-ios-simulator`).
- If build fails with "Reachable SDK package ocaml-ios64-simulator ... missing from logseq_journal.opam.locked": the lockfile lacks the simulator SDK entry — add `"ocaml-ios64-simulator" {= "5.1.1"}` next to `"ocaml-ios64"`.
- DISK SPACE: a 103MB debug.dylib + DerivedData needs several GB free. With <500MB free, codesign fails with "internal error in Code Signing subsystem" (misleading — it's just ENOSPC). Check `df -h` first; `xcrun simctl delete <unused-udid>` and `opam clean` free space quickly.

## Signing / entitlements

- `bonsai-swiftui build ios --simulator` produces an unsigned app (`CODE_SIGNING_ALLOWED=NO`, empty entitlements). Empirically on iOS 26.5 simulator this app still signs in, unlocks the E2EE graph, syncs, and uploads — keychain -34018 did NOT reproduce. If it does fail, the adhoc rebuild documented in the blueprint works:
  `xcodebuild -project apple/BonsaiLogseqJournal.xcodeproj -scheme BonsaiLogseqJournal-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/DerivedData -clonedSourcePackagesDirPath _build/bonsai-swiftui/dependencies/packages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates ARCHS=arm64 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build`
- If you must sign manually: use `.../BonsaiLogseqJournal-iOS.build/BonsaiLogseqJournal.app-Simulated.xcent` (contains FAKETEAMID application-identifier + keychain-access-groups), NOT `.app.xcent` (empty) and NOT the raw `config/entitlements/*.entitlements` (unexpanded `$(AppIdentifierPrefix)`). Do not remove `BonsaiLogseqJournal.debug.dylib` — the 59KB main binary is just a launcher for it; removing it makes the app fail to launch ("did not return a process handle").

## Install / launch / record

- `xcrun simctl install booted <path>.app`; `xcrun simctl launch booted com.example.bonsaiFlutterLogseqJournalHost` (bundle id from bonsai-swiftui.sexp ios section).
- `open -a Simulator` shows the window; `xcrun simctl io booted recordVideo out.mov` records device-only video (SIGINT to stop); `xcrun simctl io booted screenshot out.png`.

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

## Devin Secrets Needed

- `LOGSEQ_JOURNAL_USERNAME`, `LOGSEQ_JOURNAL_PASSWORD`, `LOGSEQ_JOURNAL_E2EE_PASSWORD`
