# Browser authentication acceptance

Current source reference: logseq/chat `a136ba3fc02d3dd717cb5f097686f29ce2bfb36b`,
`apple/Sources/LogseqChat/CognitoOAuth.swift` and `CognitoAuthProvider.swift`.
Journal uses ASWebAuthenticationSession, code + S256 PKCE, state and OIDC nonce.
It requests only `openid`. Account recovery and configured challenges belong to
Cognito's web page. The native app collects no credentials.

Run `python3 tool/test_swiftui_authentication.py` for presentation owner actions,
then `python3 tool/test_swiftui_cognito.py` for the public session owner against an
independent synthetic RS256 issuer. These tests never access production
Keychain, real accounts or GUI. Tests cover exact callback identity, ambiguous
parameters, state/replay/expiry, JWT signature/issuer/audience/nonce, cold restore,
ID-token expiry, refresh singleflight and retries, invalid-grant retirement,
sign-out and stale completion fencing, including cancellation during secure save.
`python3 tool/test_swiftui_services.py` retains account/graph protocol and storage
threading checks. `python3 tool/test_swiftui_events.py` retains lifecycle checks.

`python3 tool/build_authentication_probe.py` builds a disposable Simulator
application with the production view and a local presentation provider. Scenarios
are `success`, `error`, `cancel` and `busy`. The optional `--large-text`, `--dark` and
`--rtl` launch arguments retain visual checks. It does not open a real browser or
validate Cognito. Coordinate GUI ownership before installing or launching it.
The Continue button, progress, retry, Cancel, Close and sheet dismissal should be
reachable in portrait/landscape with large text. No username/password fields
remain. Do not label unobserved visual acceptance as passed.

## Real Cognito prerequisite

Pool `us-east-1_dtagLnju8`, client `69cs1lgme7p8kbgld8n5kseii6`, domain
`logseq-prod.auth.us-east-1.amazoncognito.com` match the existing Journal client
and current Chat config. A user/admin must confirm the public client has no
secret, supports authorization-code OAuth and Cognito managed/hosted login,
allows `openid`, and has exact callback `logseqjournal://auth/callback` registered.
No additional scope, logout redirect or AWS credentials are needed by this code.
The build script registers `logseqjournal` in generated host Info.plist before
signing. Registration on Cognito has not been verified or changed by this task.

After secure handoff, the user enters credentials directly into the system
browser and handles the OS sign-in prompt. Verify success, web account recovery,
user cancel, offline retry, relaunch and sign-out, and confirm existing local
Graph/E2EE account scope through public application behavior. Do not record
tokens, passwords or authorization codes, install on a physical device, or open
personal graphs without separately authorized acceptance scope.

## Storage and upgrade

OAuth tokens use the same app Keychain access identity with a dedicated generic
password item `com.logseq.journal.cognito.tokens` / `current-session`, Data
Protection Keychain, non-synchronizable, AfterFirstUnlockThisDeviceOnly. Existing
local-account-binding and E2EE key queries remain unchanged. Existing Amplify
sessions require one new web sign-in; no SDK fallback decodes old credentials.
Successful OAuth commit retires the exact old SDK session item; explicit sign-out
also clears it. All blocking storage calls serialize outside MainActor. A cancelled
secure save rolls back its own write without overwriting a newer account.
Sign-out clears local OAuth credentials before bounded best-effort remote
revocation. Ephemeral browser sessions avoid retaining Cognito browser cookies.
Transient refresh failure retains stored credentials; invalid_grant clears the
session and reopens the existing authentication gate. Revocation of already
issued JWTs remains enforced by Cognito/the existing API security boundary.
