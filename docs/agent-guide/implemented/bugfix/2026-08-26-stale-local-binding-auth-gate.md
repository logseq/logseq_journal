# Stale Local Binding Auth Gate

## Problem

The host treats a persisted local account binding as sufficient to bypass the
Amplify `Authenticator`. This is necessary for encrypted offline warm starts,
but the binding can outlive the Amplify session. When online recovery later
requests a fresh ID token, a signed-out session raises `SignedOutException`.
The worker reports `ID token acquisition failed` while the host continues to
bypass the sign-in UI, leaving the user in a retry loop that cannot recover.

## Decision

Treat a signed-out ID-token request as proof that the local account binding is
stale. Clear only that binding and switch the host back to its existing online
authentication gate before propagating the token failure. Preserve the current
offline-first startup behavior: a valid local binding must still render the
local graph without consulting Amplify until an online operation requires a
token.

The change is limited to the Flutter host adapter and its behavior tests. It
does not change worker protocols, E2EE storage, graph metadata, or token
transport.

### Implementation outcome

The ID-token request handler now catches only `SignedOutException`, clears the
persisted local account binding through the existing host callback, and
rethrows the authentication failure so the worker retains its normal challenge
semantics. Clearing the binding updates the host notifier and replaces the
local-only host with the existing Amplify authentication gate.

The regression test first failed because the clear callback was never invoked.
It now verifies both the signed-out transition and the inverse case where a
non-authentication token failure preserves the local application. All Flutter
tests and `flutter analyze` pass. A signed macOS Debug build reproduced
`wrappedGraphKeyUnavailable`; after selecting `Continue online`, it presented
the Sign in form instead of `ID token acquisition failed`.

## Alternatives considered

### Always validate Amplify before local startup

Always call `fetchAuthSession` before rendering a locally bound graph. This was
not selected because it would remove the encrypted offline warm-start behavior
and make local availability depend on network authentication.

### Keep the binding and add another retry action

Continue showing the worker recovery error and let the user retry token
acquisition. This was not selected because a signed-out Amplify session cannot
recover through retry alone and the existing `Authenticator` is the canonical
sign-in surface.

## Acceptance criteria

- A persisted local binding still starts the local lane without consulting
  Amplify.
- If a fresh ID-token request reports `SignedOutException`, the persisted local
  binding is cleared and the host switches to the online authentication gate.
- Non-authentication token failures do not clear the local binding.
- After the user signs in, the existing authenticated-user event can resume
  reconciliation without a compatibility path.
- Focused Flutter tests pass, and the macOS stale-binding recovery smoke test
  reaches the Sign in form instead of `ID token acquisition failed`.

## Consequences

- A stale binding no longer traps signed-out users behind an unrecoverable
  online-recovery retry.
- Offline warm start remains independent of Amplify until an operation actually
  requires a fresh ID token.
- Clearing the stale binding intentionally requires the next authenticated
  operation to complete through the canonical Sign in form.

## Risks

- A transient failure misclassified by Amplify as `SignedOutException` will
  require the user to sign in again. Other exception types intentionally keep
  the offline binding and current retry behavior.

## Questions

- None. The observed failure and existing offline-start requirement define the
  required behavior.
