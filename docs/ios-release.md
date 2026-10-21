# Journal iOS release

Journal is a native iPhone target: `TARGETED_DEVICE_FAMILY=1`, final
`UIDeviceFamily=[1]`. Keep the existing iPhone orientations. This does not prohibit
iPad compatibility-mode installation.

## Supported path and limits

Use the maintained [Apple build entry](../.agents/skills/journal-build/SKILL.md)
to produce a current, hash-verified device build receipt. The Fastlane preparation
lane reuses its native object and target C object, and builds Swift as Release.
At present this adapter supports only **explicit experimental host-restamp**.
It preserves `JournalCrossABIValidated=false`, the source SHA and actual native
configuration. An Xcode Release archive or Apple accepting an upload does not
prove full iOS cross-compilation, ABI correctness, runtime acceptance or testability.
There is no implicit production cross-release fallback.

Use a clean checkout and a prepared, clean LUI checkout matching the receipt.
Never edit a receipt to make stale inputs pass. New source revisions require new
verified receipts; compatible caches may be reused through the build entry.
Coordinate build/cache ownership with other tasks. No lane runs `clean`, installs
dependencies, creates certificates/profiles, or installs on a phone.

## Dependencies and separate lanes

On a Mac with Xcode and Ruby 3.4, run `bundle install` using the checked-in lockfile
(RubyGems). Keep Bundler's local dependencies outside tracked source. Set
`FASTLANE_OPT_OUT_USAGE=1` and `FASTLANE_SKIP_UPDATE_CHECK=1` before the CLI.
Do not put passwords, tokens or private keys in lane parameters or shell commands.

The following variables denote **operator-selected external paths**, not defaults:
`RELEASE_DIR` for a new release, `RELEASE_CACHE` for an exclusively owned reusable
cache, `RELEASE_STATE` for durable attempt history, `DEVICE_RECEIPT` and
`LUI_PACKAGE` for existing verified inputs. All generated outputs stay outside
the repository. Preserve old packages and attempt records. Use an unused release
directory; serialize access to each cache.

```sh
bundle exec fastlane ios prepare manifest:"$DEVICE_RECEIPT" lui:"$LUI_PACKAGE" \
  prepared:"$RELEASE_DIR/prepared" version:"$VERSION" build:"$BUILD" experimental:true
bundle exec fastlane ios archive prepared:"$RELEASE_DIR/prepared" \
  archive:"$RELEASE_DIR/Journal.xcarchive" cache:"$RELEASE_CACHE"
bundle exec fastlane ios export prepared:"$RELEASE_DIR/prepared" \
  archive:"$RELEASE_DIR/Journal.xcarchive" output:"$RELEASE_DIR/export" \
  profile:"$EXISTING_APPSTORE_PROFILE" identity:"$EXISTING_CERTIFICATE_SHA1"
```

Signing uses an existing local Apple Distribution identity and Journal App Store
profile. Acquire any necessary signing access through your approved secure
workflow; these lanes never change the signature repository, create identities,
import keys, or alter Keychain permissions. A macOS signing permission prompt
must be handled locally by its owner. Do not weaken access controls to suppress it.

Export preserves version/build numbers, verifies dSYM UUIDs at archive time, and
writes `export/verification.json`. Final IPA verification checks its SHA256,
Bundle, Team, version/build, device family, encryption declaration, source SHA,
experimental provenance, code signature, App Store profile, signed entitlements,
certificate membership, arm64 architecture and iPhoneOS Mach-O platform.
It does not certify full runtime ABI compatibility.

## Upload and repeat-attempt rules

Stable identity is `com.logseq.journal`, Developer Team `K378MFWK59`, ASC app
`6824952205`, account `dev@logseq.com`. Do not replace the original Logseq app.

Before **each attempt**, inspect that app's ASC Build Uploads and TestFlight
records for the same version/build. Check for active uploads and confirm that
automatic distribution cannot send the build to any non-target group. An empty
build list alone does not resolve an interrupted transport or pending upload.
If Apple has received the build, follow that build instead of uploading again.

After the check, copy `verification.json` to an external `receipt-check.json` and
add these operator-attested fields: `checked_utc` (current UTC ISO8601),
`accepted_build_visible: false`, `active_upload: false`, and
`non_target_automatic_distribution: false`. Keep all verification fields intact.
The upload gate requires an exact package match and a check less than 15 minutes
old. This file records a human ASC check; it is not an automated Apple API result.

```sh
bundle exec fastlane ios upload ipa:"$RELEASE_DIR/export/Journal.ipa" \
  version:"$VERSION" build:"$BUILD" sha256:"$IPA_SHA256" experimental:true \
  state:"$RELEASE_STATE" receipt_check:"$RELEASE_DIR/receipt-check.json"
```

Run locally in a terminal. Enter the existing App-specific password in the hidden
prompt, never in chat, arguments, an env file, history or a saved credential store.
The password is supplied only to this process and Apple's upload child, using an
environment-variable reference in the Altool command. The IPA is copied and
hash-checked before upload. Only the sanitized error text and process exit code
are persisted. The uploader does not perform ordinary Apple login, 2FA, credential
creation or credential-store fallback. It does not automatically retry.

Use the **same durable state directory** for this app. A lock and per-build attempt
records prevent a silent repeat, including a changed IPA with the same build.
If an attempt failed or was interrupted, first resolve Apple receipt status and
get authorization for another attempt. Only then pass `retry_upload:true` with a
fresh exact-package check. A tool-reported successful upload is never retried by
this entry. Do not delete locks/history, increment the build number, or change
state directories merely to escape an uncertain result.

## Completion and distribution

Track these separately: tool upload result; Apple's delivery UUID/receipt;
processing Complete/Invalid; Missing Compliance or cleared compliance; and the
specific group's Ready to Test/Testing state. Exit 0 alone is not success:
Altool can print `ERROR:` with exit 0. Full sanitized multiline/structured errors
are retained alongside the exit code. Never infer a password or ABI cause from
a generic failure. Preserve the report, inspect Apple, then decide the next step.

Upload explicitly skips submission, waiting and tester distribution. After Apple
processing and compliance are resolved, assign only the existing internal
**Logseq Team** group (`3fcd1cd3-cafa-44e4-987d-47a752174c32`) in ASC under separately
authorized account access. Check the group belongs to Journal and verify build
availability there. No lane selects all groups, invites testers, enables external
testing or publishes to the App Store. App-specific upload credentials do not
provide group-management access.

## Encryption declaration basis

`apple/Info.plist` carries `ITSAppUsesNonExemptEncryption=false`, matching the
team's original Logseq iOS declaration at
[3d41a46](https://github.com/logseq/logseq/blob/3d41a46bcd40b07c60856f76f4ea1ad89aad1db7/ios/App/App/Info.plist#L53).
The owner confirmed the same encryption implementation applies to Journal; this
configuration carries forward the existing team declaration. It is not a general legal guarantee.
Apple defines `false` as either no encryption **or only exempt encryption**,
including linked third-party libraries; it does not mean no cryptography exists.
See [Apple's key semantics](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption).

Graph/assets use AES-GCM via CryptoKit and RSA-OAEP via Security; Swift implements
PBKDF2 using CryptoKit HMAC-SHA256. OCaml TLS/Mirage-crypto is also shipped.
Algorithm-type questionnaire answers and documentation exemptions are distinct.
Reassess the declaration when encryption functionality, dependencies or intended
distribution changes, including applicable France requirements. Never set `false`
solely to bypass Missing Compliance. A previously uploaded build missing this
key can have its declaration completed in ASC without reuploading just for this key.

## Offline verification

```sh
bundle exec ruby test/test_journal_release.rb
PYTHONDONTWRITEBYTECODE=1 python3 .agents/skills/journal-build/scripts/test_journal_build.py
```

The release tests use synthetic data and the actual pinned Pilot/Altool parser
with its PTY execution replaced. No Apple network call, credential store, signing
identity or graph is used. No release lane runs in CI. Keep credentials, profiles,
private certificates/keys, recovery GPG material, graphs, raw upload logs,
IPAs/archives/dSYMs and local attempt evidence outside Git.
