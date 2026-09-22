# Keep Account Storage Off Main Thread

## Problem

Launching the current macOS production app leaves its entire window unresponsive
while Keychain authorization is pending. Two Computer Use observations time out.
A three-second sample of PID 75474 attributes every main-thread sample to
JournalPlatformServices.localAccount -> JournalLocalAccountBindingStore.load ->
SecItemCopyMatching. The system authorization remains user-controlled; this
decision does not change access controls or attempt to operate SecurityAgent.

## Decision

Make the account capability asynchronous. Execute native account load/save/clear
on one serial background DispatchQueue and return only typed Sendable account
values. Keep presentation/authentication state on MainActor. Revalidate request
generation and cancellation after suspension so sign-out or runtime replacement
cannot admit stale authentication results. Preserve sign-out cleanup even when
its requesting task disappears, and order native saves before subsequent clears.

The production owner is Swift native capability execution. The OCaml sync pure
reducer only emits requests and consumes completions; its public events/state
cannot execute MainActor or Keychain calls. Reproduce at the narrow native factory
boundary with a synchronously blocking disposable storage stand-in. Retain the
live stack as actual-system evidence. No crypto, transport or reducer duplicate
regression is justified, and no protected interface/SDK changes are needed.

## Alternatives considered

### Ask the user to authorize and leave synchronous calls on MainActor

Authorization is still needed for the real account, but waiting must not freeze
the app. Moving the same calls off MainActor preserves system security behavior.

### Suppress authorization or alter Keychain permissions

Rejected. This would change security behavior instead of repairing UI execution.

## Acceptance criteria

- Record a behavioral failing native factory test before implementation.
- While native storage is held, MainActor remains responsive and no storage
  operation runs on the main thread; load/save/clear preserve ordering.
- In-flight account lookup is rejected after sign-out or runtime invalidation.
- Existing offline binding, preferences, tokens and sign-out tests pass.
- Build macOS and iPhone source targets and inspect actual macOS startup while
  retaining any authorization blocker honestly; do not access the iPhone.
- No real secrets in test logs, no Dune/spec edits and no security-setting changes.

## Risks

- Async suspension adds reentrancy to account reads/writes. Generation fencing
  and serialized native storage must prevent stale replies and reordered cleanup.
- The system may continue waiting for user authorization; this fix keeps the UI
  responsive and does not make credentials available without consent.

## Questions

- None for implementation. Manual system authorization is separately pending for
  real-account acceptance and is not needed for the isolated regression.

## Consequences

Implemented with behavioral RED/GREEN evidence. The original platform suite and
new native-factory blocking-storage regression both pass, as does `dune runtest`.
macOS Debug and iPhoneOS Release builds pass without installing on the phone.

The rebuilt macOS production application (PID 78634) exposes a responsive native
window while the real account read still waits. Account menu and Diagnostics
open, and Close returns to startup. A new three-second sample places the Keychain
wait on `com.logseq.journal.account-storage`; MainActor runs its normal event
loop instead of waiting in Security IPC. This proves the targeted responsiveness
repair without claiming that the user has authorized access or completed actual
authentication. The original process was terminated after sampling and before
rebuilding. Keychain settings and credentials were not modified.

See `docs/test-reports/2026-09-16-native-swiftui-standardization/batch50-account-startup.md`
for retained tests, build setup failure, samples and platform limits. The broader
iPhone standardization goal remains open.
