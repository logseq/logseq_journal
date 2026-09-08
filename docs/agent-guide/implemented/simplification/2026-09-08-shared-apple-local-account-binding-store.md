# Shared Apple Local Account Binding Store

## Problem

The iOS and macOS production hosts contain byte-for-byte copies of
`JournalLocalAccountBindingStore`. The copy in
`flutter/ios/Runner/AppDelegate.swift` and the copy in
`flutter/macos/Runner/MainFlutterWindow.swift` each own the same Keychain query,
JSON encoding and validation, bounded decoding, load, save, and clear behavior.
Each copy is approximately eighty lines of security-sensitive implementation.

Both stores use the same persisted contract:

- generic-password service `com.logseq.journal.local-account-binding`;
- account `current-managed-sync-account`;
- `AfterFirstUnlockThisDeviceOnly` accessibility and no synchronization;
- a version-1 JSON object containing `userId` and `managedSyncOrigin`; and
- the same 4,096-byte item bound and origin/user validation.

The production consumers are also equivalent. Each platform's startup
environment calls `load`, and each platform method channel calls `save` for
`setLocalAccountBinding` and `clear` for `clearLocalAccountBinding`. The iOS and
macOS Runner test targets call `query`, `encode`, and `decode`. Repository search
found no other source consumer and the enum is not an external Swift API.

Maintaining two independent copies creates two owners for one persisted security
contract. A future validation, accessibility, or item-identity change can reach
one platform without the other even though the intended behavior is identical.
This is accidental duplication rather than platform policy: the repository
already compiles the shared `flutter/JournalE2EECrypto.swift` source into both
Runner targets through their Xcode project files.

## Decision

The unchanged `JournalLocalAccountBindingStore` implementation now lives in
`flutter/JournalLocalAccountBindingStore.swift`. Both the iOS and macOS Runner
targets compile that file using the same Xcode source-reference pattern as
`JournalE2EECrypto.swift`. Both inline enum copies and their unused Security
imports have been removed.

Keep the current name and function signatures so the two startup-environment
readers, two method-channel handlers, and both Runner test targets continue to
consume the same private type without adapters. Preserve every Keychain
attribute, validation rule, byte bound, JSON field, error behavior, delete-then-
add save sequence, and return shape exactly. The existing persisted item remains
the only format; add no migration, fallback, compatibility decoder, or second
service.

The user confirmed that this decision is limited to the exact shared store. Keep
`JournalPlatformEnvironment` in each platform because its payload and filesystem
policy differ. Keep Flutter method-channel setup in each platform because iOS and
macOS import different Flutter frameworks and own different engine/window
lifecycles. Do not merge the local-account-binding Keychain service with the E2EE
private-key or wrapped-graph-key services; their identities and lifecycle rules
remain deliberately disjoint under the implemented key-cache architecture.

## Alternatives considered

### Keep the platform copies

This avoids Xcode project edits but retains two owners for identical persisted
data and validation. The existing shared Swift source establishes that a common
file is supported by both Runner targets.

### Share the complete platform method handler

The method switch is also substantially duplicated, but extracting it requires a
cross-platform abstraction over Flutter framework types and platform-specific
startup-environment construction. That moves rather than removes lifecycle
complexity and is not needed to eliminate the proven store duplication.

### Add the store to JournalE2EECrypto

The two implementations both use Keychain APIs, but they protect different data
and follow different lifecycle contracts. The implemented wrapped-graph-key
decision explicitly keeps private-key, wrapped-key, and local-account-binding
services disjoint. A separate shared file removes platform duplication without
combining those ownership boundaries.

## Acceptance criteria

- Exactly one production definition of `JournalLocalAccountBindingStore` exists,
  and both Runner targets compile it from
  `flutter/JournalLocalAccountBindingStore.swift`.
- iOS and macOS preserve the exact current Keychain service, account,
  accessibility, synchronization, JSON schema, validation, size limit, load,
  save, clear, and error behavior. Existing stored items remain readable without
  migration or fallback logic.
- The platform-specific startup environments and method-channel lifecycles remain
  in their current host files; no shared abstraction is added for divergent
  platform policy.
- Existing iOS and macOS Runner tests continue to exercise the shared store. Do
  not remove or move existing coverage as part of this simplification.
- `bonsai-flutter sync-host --check`, Flutter analysis and tests, both Runner test
  targets, and unsigned iOS and macOS builds pass. Both built targets must contain
  the shared source and no duplicate store symbol.
- `spec-dev-tool check --all` and repository diff checks pass. No OCaml file under
  `spec/`, Dune file, or bonsai_flutter repository source is modified.

## Risks

- An Xcode project can accidentally reference the shared file without placing it
  in the corresponding Sources phase. Build and Runner-test validation must cover
  both targets.
- Platform Keychain APIs share declarations but can differ in entitlement and
  runtime behavior. The proposal preserves existing attributes and retains both
  platform test lanes rather than assuming one platform proves the other.
- Generated-host synchronization could overwrite project structure if the shared
  reference is not compatible with the existing host layout. The required
  `sync-host --check` gate must remain clean.
- Expanding the scope to channel dispatch or E2EE storage would create a broader
  architecture change and weaken the net-deletion argument.


## Validation

Verified on 2026-09-08:

- The shared enum body matches both original platform copies byte-for-byte.
  The host files differ only by removal of the enum and unused Security import.
  Exactly one production definition remains. The five Swift/Xcode source changes
  remove 77 lines net, including the new shared file.
- Both Xcode project files pass `plutil -lint`. Both Runner compilation logs name
  `flutter/JournalLocalAccountBindingStore.swift`. Each built Debug dylib contains
  16 distinct store symbols and exactly one `query()` implementation.
- The existing macOS Runner suite passes before and after extraction: 12 passed,
  one opt-in real-Keychain test skipped. The existing iOS Runner suite passes on
  the connected iPhone: three passed, one opt-in real-Keychain test skipped.
  Existing tests were neither changed nor duplicated.
- Flutter analysis reports no issues. Flutter tests pass: 80 passed, seven
  existing skips. Both commands ran through the installed `bonsai-flutter exec`
  with the Debug native artifact.
- `bonsai-flutter build ios --profile=debug --no-codesign` passes, including the
  tool's native object and app-bundle verification. The macOS Debug unsigned build
  passes with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`, using the native
  artifact built by the installed `bonsai-flutter exec` for the Runner test lane.
- `bonsai-flutter sync-host --check`, `spec-dev-tool check --all`, and
  `git diff --check` pass after the profile-scoped commands finish and restore
  their temporary `pubspec.yaml` profile setting.
- This implementation changes no OCaml source, Dune file, or bonsai_flutter
  repository source. Pre-existing unrelated working-tree changes are preserved.

## Consequences

The two Apple hosts now share one owner for the persisted local-account-binding
contract. Future store changes apply to both platforms through one source file.
Platform startup environments, method-channel lifecycles, and the separate E2EE
Keychain services retain their existing ownership and behavior.
