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
Preparation fixes the receipt digest and native linker paths. Replacing a receipt
or changing the prepared project's link inputs requires a new prepared project.
Coordinate build/cache ownership with other tasks. No lane runs `clean`, installs
dependencies, creates certificates/profiles, or installs on a phone.

## Dependencies and separate lanes

On a Mac with Xcode and Ruby 3.4, run `bundle install` using the checked-in lockfile
(RubyGems). Keep Bundler's local dependencies outside tracked source. Set
`FASTLANE_OPT_OUT_USAGE=1` and `FASTLANE_SKIP_UPDATE_CHECK=1` before the CLI.
Do not put passwords, tokens or private keys in lane parameters or shell commands.
The release driver keeps a UTF-8 locale if one is configured and sets
`LANG` and `LC_ALL` to `en_US.UTF-8` when the effective locale uses another encoding.
Set `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` before running lanes directly if
Fastlane reports `invalid byte sequence in US-ASCII` while reading Xcode output.

The following variables denote **operator-selected external paths**, not defaults:
`RELEASE_DIR` for a new release, `RELEASE_CACHE` for an exclusively owned reusable
cache, `RELEASE_STATE` for durable attempt history, `DEVICE_RECEIPT` and
`LUI_PACKAGE` for existing verified inputs. All generated outputs stay outside
the repository. Preserve old packages and attempt records. Use an unused release
directory; serialize access to each cache.

TestFlight build numbers use `yyyymmddXXXX`: the UTC date followed by a
zero-padded four-digit global sequence. The sequence is not date-scoped and does
not reset; each release adds one to the latest sequence visible in App Store
Connect, including legacy dotted build numbers such as `1.5877.91`. Generate it
immediately before preparation and use the same value for every later lane:

```sh
BUILD="$(bundle exec ruby fastlane/next_testflight_build_number.rb)"
```

The script requires the ASC API key environment described below. It fails rather
than resetting the sequence if no prior sequence is visible or the four-digit
suffix is exhausted.

### One-command TestFlight release

`fastlane/release_testflight.sh` is the preferred operator entry when the intent
is to publish the current `origin/main`. It requires a clean main checkout,
verifies that checkout is still the remote main tip, generates the build number,
runs prepare/archive/export, validates the exported IPA, re-checks the build
sequence, source revision and IPA hash immediately before upload, then runs the
automated publish lane. It intentionally refuses an existing `RELEASE_DIR` and a
stale or dirty main checkout. It does not provision signing material or repair a
keychain.

```sh
MAIN_WORKTREE="$MAIN_WORKTREE" \
DEVICE_RECEIPT="$DEVICE_RECEIPT" \
LUI_PACKAGE="$LUI_PACKAGE" \
RELEASE_DIR="$RELEASE_DIR" \
RELEASE_CACHE="$RELEASE_CACHE" \
RELEASE_STATE="$RELEASE_STATE" \
EXISTING_APPSTORE_PROFILE="$EXISTING_APPSTORE_PROFILE" \
EXISTING_CERTIFICATE_SHA1="$EXISTING_CERTIFICATE_SHA1" \
fastlane/release_testflight.sh
```

The script stores step logs and a small `release-summary.json` in the external
release directory. For debugging or staged manual operation, the same path can
still be run lane by lane:

```sh
BUILD="$(bundle exec ruby fastlane/next_testflight_build_number.rb)"
bundle exec fastlane ios prepare root:"$MAIN_WORKTREE" manifest:"$DEVICE_RECEIPT" lui:"$LUI_PACKAGE" \
  prepared:"$RELEASE_DIR/prepared" version:"$VERSION" build:"$BUILD" experimental:true
bundle exec fastlane ios archive prepared:"$RELEASE_DIR/prepared" \
  archive:"$RELEASE_DIR/Journal.xcarchive" cache:"$RELEASE_CACHE"
bundle exec fastlane ios export prepared:"$RELEASE_DIR/prepared" \
  archive:"$RELEASE_DIR/Journal.xcarchive" output:"$RELEASE_DIR/export" \
  profile:"$EXISTING_APPSTORE_PROFILE" identity:"$EXISTING_CERTIFICATE_SHA1"
```

Signing uses an existing local Apple Distribution identity and Journal App Store
profile. The Fastlane lanes expect those inputs to be available already.

### Signing preparation on a fresh macOS host

For a host with no configured release identity, inject these existing repo-scoped
secrets into the process environment through the approved secret manager:

- `JOURNAL_IOS_APPSTORE_PROFILE_BASE64`
- `JOURNAL_IOS_DISTRIBUTION_P12_BASE64`
- `JOURNAL_IOS_DISTRIBUTION_P12_PASSWORD`

With the remaining release variables set as above, start the driver in a temporary
signing environment:

```sh
bundle exec ruby fastlane/with_testflight_signing.rb -- fastlane/release_testflight.sh
```

The wrapper validates the profile's app, team, expiry, and entitlements, then
imports the existing identity into a temporary keychain and signs a local probe
before starting the command. It supplies `EXISTING_APPSTORE_PROFILE` and
`EXISTING_CERTIFICATE_SHA1` to the child. For earlier device-receipt preparation,
run the device build in the same wrapper and pass
`JOURNAL_IOS_SIGN_ENTITLEMENTS` to the build entry's `--sign-entitlements` option
along with the provided profile and certificate fingerprint. The child does
not inherit the three signing secrets.

The wrapper serializes temporary signing setup for the current Mac user. It
removes its keychain and any profile it installed when the command exits,
including on handled interruption. Existing profiles are reused only when
their contents match. Keep signing commands under the wrapper for as long as
they use its temporary paths. If the signing probe fails to build a trust
chain, check Apple's WWDR G3 intermediate in the login keychain and use the
Apple Certificate Authority copy through your approved local procedure. Keep
the existing trust settings and retry the signing probe before building.

### Local export verification

Export preserves version/build numbers, verifies dSYM UUIDs at archive time, and
writes `export/verification.json`. The export lane temporarily limits child
processes to system paths because Xcode's `/usr/bin/rsync` delegates to `rsync`
from `PATH`; Homebrew rsync rejects the legacy flags used by Xcode export.
Final IPA verification checks its SHA256,
Bundle, Team, version/build, device family, encryption declaration, source SHA,
experimental provenance, code signature, App Store profile, signed entitlements,
certificate membership, arm64 architecture and iPhoneOS Mach-O platform. Source
SHA must equal the current verified receipt, not merely have the right format.
It does not certify full runtime ABI compatibility.

## Upload and repeat-attempt rules

Stable identity is `com.logseq.journal`, Developer Team `K378MFWK59`, ASC app
`6824952205`, account `dev@logseq.com`. Do not replace the original Logseq app.
`SOURCE_SHA` is the intended full source revision from the verified build receipt;
the upload preflight requires an exact match in the IPA.

### Automated TestFlight publish

Use `ios publish` for the unattended path. It verifies the exact IPA offline,
uses the App Store Connect API to reject a visible or active duplicate build,
checks that no non-target beta group automatically receives all builds, uploads
with Pilot, waits for processing, assigns only the internal **Logseq Team** group,
and re-queries that assignment. It never selects all groups, invites testers,
enables external testing or publishes to the App Store.

Apple ID passwords are not sufficient for unattended group management: ASC web
login requires interactive 2FA, and an app-specific password only authenticates
the binary transporter. Provide a team App Store Connect API key with enough
TestFlight/administration privilege through process environment variables, never
lane arguments or files in Git:

- `JOURNAL_ASC_KEY_ID`
- `JOURNAL_ASC_ISSUER_ID`
- `JOURNAL_ASC_PRIVATE_KEY` (PEM content) or `JOURNAL_ASC_PRIVATE_KEY_BASE64`

The key can be created in ASC under Users and Access → Integrations → App Store
Connect API. Keep the downloaded `.p8` outside Git. The lane reads key material
into the release process, uses fastlane's API-key transporter support and does
not store it in a credential manager.

```sh
bundle exec fastlane ios publish ipa:"$RELEASE_DIR/export/Journal.ipa" \
  version:"$VERSION" build:"$BUILD" sha256:"$IPA_SHA256" source:"$SOURCE_SHA" experimental:true \
  state:"$RELEASE_STATE" wait_timeout:3600
```

The automated preflight replaces the human receipt check below. If it reports
that Apple has already received the build, follow that build instead of uploading
again. The publish lane checkpoints transporter success and the Apple receipt
in the attempt record under `RELEASE_STATE` before waiting for Apple processing.
It prints observed processing and distribution milestones as the state changes.
A recorded successful transport blocks another upload even if the delivery UUID
was temporarily unavailable.

### Check status or resume after an interruption

Use the exact same version/build and the delivery UUID from the publish output,
the attempt's `apple_build_id`, or App Store Connect Build Uploads. Querying
status is read-only and can run while the original publish is waiting:

```sh
bundle exec fastlane ios testflight_status \
  version:"$VERSION" build:"$BUILD" apple_id:"$APPLE_BUILD_ID"
```

For a recorded automated publish whose process has stopped, use the same durable
`RELEASE_STATE` directory:

```sh
bundle exec fastlane ios resume_testflight \
  version:"$VERSION" build:"$BUILD" apple_id:"$APPLE_BUILD_ID" \
  state:"$RELEASE_STATE" wait_timeout:3600
```

Resume verifies the UUID against the exact Journal version/build in ASC, waits
if needed, and assigns only the existing internal Logseq Team group. It does
not need the IPA or signing secrets because it cannot upload. If the original
process stopped before saving the receipt, use the matching UUID from ASC.
Keep the attempt record even after a timeout, and use status or resume once
Apple reports the build again.

| Status | Meaning and next step |
| --- | --- |
| `awaiting_apple_receipt`, `awaiting_upload`, `processing` | The build is not yet installable. Check Build Uploads, then resume the existing attempt after it stops. |
| `compliance_pending` | ASC reports missing export compliance or review in progress. Check the build in ASC and resume after the declaration or review is resolved. |
| `ready_to_assign` | Apple reports a valid build ready for testing. Resume can assign the group or verify a pending assignment. |
| `published_to_logseq_team` | ASC reports `VALID`, an internal Ready to Test or Testing state, and verified Logseq Team membership. |
| `upload_failed`, `processing_failed`, `failed_or_uncertain` | Inspect Apple and the existing attempt before taking any action. A repeat upload requires the checks below. |

### Manual upload-only fallback

Before **each manual attempt**, inspect that app's ASC Build Uploads and TestFlight
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
  version:"$VERSION" build:"$BUILD" sha256:"$IPA_SHA256" source:"$SOURCE_SHA" experimental:true \
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

`ios publish` waits for processing, assigns only the existing internal
**Logseq Team** group (`3fcd1cd3-cafa-44e4-987d-47a752174c32`) and verifies the
result through ASC before exiting successfully. The manual `ios upload` lane
still skips submission, waiting and tester distribution. If that fallback is
used, assign the same group later under separately authorized account access and
verify build availability there. No lane selects all groups, invites testers,
enables external testing or publishes to the App Store. App-specific upload
credentials do not provide group-management access.

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
PYTHONDONTWRITEBYTECODE=1 python3 .agents/skills/journal-build/scripts/test_journal_build.py
```

Run the offline recovery regression with:

```sh
bundle exec ruby test/test_testflight_recovery.rb
```

Release tooling was also checked using temporary, external synthetic fixtures and the
actual pinned Pilot/Altool parser with its PTY execution replaced. Those fixtures
are not shipped in this repository. No Apple network call, credential store,
signing identity or graph is needed for that check. Keep credentials, profiles,
private certificates/keys, recovery GPG material, graphs, raw upload logs,
IPAs/archives/dSYMs and local attempt evidence outside Git.
