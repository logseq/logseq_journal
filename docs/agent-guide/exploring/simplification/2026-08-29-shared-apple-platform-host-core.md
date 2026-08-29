# Shared Apple Platform Host Core

## Problem

`flutter/ios/Runner/AppDelegate.swift` and
`flutter/macos/Runner/MainFlutterWindow.swift` independently implement the same
Apple host contract. The 295-line iOS file and 317-line macOS file differ by
only 39 added and 17 deleted lines when compared as a rename. Most of both files
is behavior-identical production code:

- the entire bounded, device-only, non-synchronizable Keychain codec and store
  for the local managed-account binding;
- local-day calculation and localized journal-day formatting;
- startup payload assembly for time, locale, typography, and local-account
  binding fields;
- validation and dispatch for every `logseq_journal/platform` method call;
- the stable Flutter error envelope; and
- calendar-change observer registration and teardown.

The genuine platform differences are narrow. iOS publishes `platform = "ios"`
and `applicationDataPath`, receives its messenger through the implicit engine,
and observes `UIApplication.significantTimeChangeNotification`. macOS publishes
`platform = "desktop"` and a canonical account `homeDirectoryPath`, creates a
window-owned `FlutterViewController`, and coordinates termination.

Both Runner test targets directly exercise their copied types. A future change
to the Keychain schema, startup payload validation, preference vocabulary,
method names, error envelope, or journal-day formatting must therefore be made
twice and can drift silently. This is production duplication, not independent
platform policy: the repository already compiles the shared
`flutter/JournalE2EECrypto.swift` source into both Xcode targets, proving the
cross-target source arrangement.

## Proposal

Add one shared Apple host source under `flutter/` and compile it into both the
iOS and macOS Runner targets, following the existing shared
`JournalE2EECrypto.swift` project-reference pattern. The shared source should
own only behavior-identical code:

- `JournalLocalAccountBindingStore` and its exact Keychain query, JSON codec,
  bounds, save/load, and cleanup behavior;
- local-day and localized journal-day formatting;
- startup payload augmentation for typography and local-account binding after a
  platform-specific base environment has been supplied;
- validation and dispatch of `getStartupEnvironment`, `formatJournalDays`,
  `getPreference`, `setPreference`, `setLocalAccountBinding`,
  `clearLocalAccountBinding`, and `e2eeCrypto`; and
- construction of the existing `journal_platform` error result.

Keep platform lifecycle and environment authority in the two target files.
Each target continues to resolve its own filesystem fields, construct its own
Flutter engine or window, provide the platform-specific base startup payload,
register its platform-specific notification set, and own teardown. The shared
dispatcher should accept the target's startup-environment function rather than
branching on platform filesystem policy.

Use one source definition, not copied generated files, symlinks, or forwarding
types. Remove the duplicate definitions from both host files and keep the
existing public method names, payload keys, Keychain identifiers and
accessibility, preference values, notification reason integers, error code and
message, and E2EE delegation unchanged. Update both Xcode project source lists
explicitly; do not add a compatibility copy.

## Alternatives considered

### Share only the Keychain store

This removes the largest exact block but leaves the method protocol, preference
validation, date formatting, and error behavior duplicated. Those surfaces have
the same cross-platform contract and benefit from one owner.

### Share the complete host implementation

The engine/window lifecycle, filesystem authority, termination, and significant
time notifications genuinely differ by platform. A single conditional-heavy
delegate would hide those differences and relocate platform complexity into the
shared layer.

### Keep the copies because they belong to separate Xcode projects

The projects already reference and compile the same root-level
`JournalE2EECrypto.swift`; separate projects are therefore not a technical
requirement for duplicate source. Keeping the copies preserves two obligations
for one contract.

### Move the contract to Dart

Keychain access, native environment paths, calendar notifications, and platform
crypto must remain native. Moving them to Dart would change authority and
failure timing rather than preserve behavior.

## Acceptance criteria

- One shared Swift source is compiled by both Runner targets and owns the common
  account-binding, date-formatting, startup augmentation, method-dispatch, and
  Flutter-error behavior.
- `AppDelegate.swift` retains only iOS engine lifecycle, iOS filesystem payload
  fields, the iOS-only significant-time notification, channel attachment, and
  teardown.
- `MainFlutterWindow.swift` retains only macOS window/engine lifecycle, canonical
  home-directory resolution, termination coordination, channel attachment,
  platform notification registration, and teardown.
- The duplicate `JournalLocalAccountBindingStore` and common method switch no
  longer exist in both target files; no generated copy, symlink, alias, or
  compatibility implementation replaces them.
- Method names, argument validation, result payloads, startup keys and values,
  Keychain service/account/accessibility/synchronization attributes, preference
  values, calendar reason integers, and the `journal_platform` error envelope
  remain exact.
- Existing iOS and macOS Runner tests still compile against the shared types and
  pass. The iOS app and RunnerTests build-for-testing, signed macOS RunnerTests,
  Flutter analyze/tests, `dune runtest`, and `git diff --check` pass.

## Risks

- Target membership mistakes can make the shared source available to one Runner
  but not its test bundle. Both project files and both build-for-testing paths
  must be validated.
- A shared dispatcher that imports too much Flutter lifecycle API could require
  conditional compilation. Keeping messenger acquisition and delegate/window
  lifecycle outside the shared source limits that risk.
- iOS and macOS startup payloads deliberately have different path keys and
  platform values. The shared code must augment a platform-owned base payload,
  not normalize these fields.
- Keychain behavior is security-sensitive. Consolidation must preserve every
  query attribute and all failure behavior, including deletion-before-add and
  corrupted/oversized binding rejection.

## Questions

- Should the shared source own the common method-dispatch switch as proposed, or
  should it stop at the Keychain/date/startup helpers and leave identical Flutter
  dispatch in both platform hosts?
