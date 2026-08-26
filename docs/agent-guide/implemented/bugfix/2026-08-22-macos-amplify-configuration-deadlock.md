# macOS Amplify Configuration Deadlock

## Problem

The production macOS entrypoint calls runApp before Amplify is configured.
ApplicationHostAdapter.createApplicationPayload starts
JournalAmplify.configure, but ApplicationHostAdapter.buildHost mounts the
Authenticator immediately around the generated loading screen. The
Authenticator accesses AmplifyAuthService while the same configuration future
is still pending.

On 2026-08-22, a fresh Debug launch remained on the Authenticator loading spinner
indefinitely. The Flutter log repeated:

    Amplify is taking longer than expected to configure. Have you called Amplify.configure()?

The widget tree never reached the sign-in form or account restoration. A test-only
entrypoint that awaited JournalAmplify.configure before runApp immediately
restored the existing Cognito session and entered the native sync manager. This
isolates the failure to startup ordering rather than credentials, Keychain access,
or Cognito availability.

## Decision

Make Amplify configuration a prerequisite for mounting any Authenticator widget.
This application will own a non-generated production entrypoint that starts
JournalAmplify.configure before calling runApp. The host may present a locally
bound Timeline while configuration is pending, but it must await configuration
before constructing Authenticator. Configuration failure must produce a bounded,
actionable error instead of an infinite spinner.

Keep exactly one configuration owner. Do not retain the current concurrent adapter
payload and Authenticator initialization paths.

### Implementation outcome

Production now uses `lib/main.dart` as its application-owned custom host entrypoint.
It initializes Flutter, starts `JournalAmplify.configure`, and passes the readiness
future into the host before calling `runApp`. A valid local account binding can
present the local Timeline while configuration is pending; a cold signed-out path
does not construct `Authenticator` until the future succeeds. Configuration
failure renders a stable error surface whose Retry action starts a fresh
configuration attempt; failed configuration futures are not cached.

macOS Debug, Profile, and Release builds all use the owned entrypoint. A real
signed-in launch reached the Journal timeline without the previous loading
deadlock, and Flutter tests verify both the pending-configuration boundary and the
retry composition.

## Alternatives considered

### Keep configuring from createApplicationPayload

Rejected because the generated host calls buildHost while the payload future is
pending. The Authenticator can therefore observe an unconfigured Amplify instance.

### Retry Amplify service access from the Authenticator

Rejected because retries preserve the startup race and hide configuration failures.
The dependency must be ready before its consumer mounts.

### Add an async pre-runApp hook to the generated host

Rejected because Amplify setup is application-specific startup policy. Expanding
the generated host API would couple shared host generation to a lifecycle decision
that this application can own explicitly in its non-generated entrypoint.

## Acceptance criteria

- The non-generated application entrypoint starts Amplify configuration before
  calling runApp and completes it before constructing Authenticator in signed
  macOS Debug and Release builds.
- A persisted Cognito session restores and reaches graph discovery without an
  Amplify configuration warning.
- A signed-out account renders the sign-in form without an indefinite loading
  state.
- An Amplify configuration failure renders one stable, actionable error and can be
  retried without mounting concurrent configuration attempts.
- A test proves that buildHost cannot construct Authenticator while Amplify
  configuration is pending.

## Consequences

- Production startup has one explicit configuration owner and never mounts an
  Authenticator against an unconfigured Amplify singleton.
- A failed configuration remains visible and retryable instead of leaving an
  indefinite loading frame.
- The application-owned `lib/main.dart` must remain the custom Flutter host.

## Risks

- Moving initialization before runApp requires an explicit startup error surface
  because no widget tree exists yet.
- The non-generated entrypoint must remain a thin application-owned composition
  layer so generated host changes cannot silently bypass it.

## Questions

- None. The application will own a non-generated entrypoint that performs Amplify
  setup before runApp.
