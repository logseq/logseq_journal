# Native Live Unlock Retry

## Problem

Correct-password E2EE unlock is verified on iPhone, but the user explicitly confirms that an incorrect password has not been tried. The existing live-account acceptance application now has a cached wrapped key and skips this flow. Its original blocked mutation records remain valuable evidence.

## Proposal

Build the unchanged current production sources under a fresh JournalUnlockRetry application identity, with its own default Keychain access group and data container. Keep the same backend configuration and native authentication/unlock views. Install and open this separate application, then ask the user to sign in, enter one incorrect E2EE password, and retry with the correct password entirely in the application. Do not ask for credentials in chat. Record the user's observed feedback, keyboard stability and successful retry; retain any actual failure for its production owner before considering a fix.

## Alternatives considered

### Delete credentials or local graph data from an existing application

Rejected because a fresh identity exercises uncached unlock while retaining current account state and rejected-write evidence.

### Inject a synthetic unlock error into the UI

Existing native/reducer tests already cover that boundary. It does not execute actual password verification against the user's encrypted graph key.

## Acceptance criteria

- Build, sign and install the same production source under the new application identity.
- Verify a distinct signed application identifier and no shared Keychain access group entitlement.
- Keep original production and account-acceptance containers and credentials intact.
- Obtain user-performed wrong-password feedback and correct-password retry observations without exporting credentials.
- Keep missing observations open and do not count preview or synthetic errors as real cryptographic verification.

## Risks

- The fresh identity requires the user to sign in again. Passwords and verification codes must remain in the application.
- Backend challenge behavior is account-dependent; report what occurs rather than forcing an account change or recovery operation.

## Questions

None for preparation. The user already authorized real-account acceptance and indicated availability; actual input must still be performed manually in the application.

## User-directed pause — 2026-09-18

The user stopped further work and closed the main UI implementation. This
follow-up remains proposed and paused; resume only on a new user request.
The independent application built successfully but was not installed or used.
Real incorrect-password feedback and correct-password retry remain unverified.
