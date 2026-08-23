# macOS Amplify Keychain Sharing

## Problem

The macOS host constructs `AmplifyAuthCognito` with its default secure-storage
factory. That factory uses the Data Protection Keychain, but the Runner's Debug,
Profile, and Release entitlements do not declare a Keychain access group. Amplify
therefore fails with Security error `-34018` before Cognito can validate a sign-in,
and the Authenticator renders only a generic error.

## Decision

Enable Keychain Sharing for every macOS application configuration by declaring the
default application access group in both Runner entitlement files. Keep Amplify's
default Data Protection Keychain behavior and require the final signed app to carry
the access group. The Runner uses bundle identifier `com.logseq.journal`, automatic
signing, and the Logseq development team so Debug, Profile, and Release resolve the
same application-scoped Keychain namespace.

This fix applies only to the Amplify Cognito session store. Journal's separate E2EE
private-key storage contract remains unchanged.

## Alternatives considered

### Disable the Data Protection Keychain on macOS

Rejected because Amplify exposes `useDataProtection: false` only for testing and
warns that disabling it lowers production security.

### Replace the Cognito session store with process memory

Rejected because production login must survive process restarts and refresh tokens
must remain in platform secure storage. The existing Debug-only process-memory mode
is intentionally scoped to the E2EE user private key, not authentication sessions.

## Acceptance criteria

- Debug/Profile and Release source entitlements declare exactly the application
  Keychain access group.
- Effective Xcode build settings use bundle identifier `com.logseq.journal`, the
  Logseq development team, and a non-ad-hoc signing identity.
- A signed macOS Debug and Release app carries `keychain-access-groups`.
- Amplify initializes without Security error `-34018`, and the production
  Authenticator can submit a real Cognito login.
- Existing Flutter, macOS Runner, and Release build checks remain green.

## Consequences

- Keychain access groups depend on correct bundle identity and code signing. A
  distributable Release build must use the intended Development Team and
  provisioning identity rather than an unrelated local identity.
- Changing the application identifier after shipping would move Amplify to a
  different Keychain namespace and invalidate persisted sessions.

## Questions

- None.
