# Cognito Web Authentication

## Problem

Journal collects passwords and depends on Amplify/AWS Swift SDK for Cognito sessions. The user requests the browser login used by current logseq/chat and removal of the SDK.

## Decision

Use ASWebAuthenticationSession with authorization code, S256 PKCE, state and nonce. Validate the exact callback and signed ID/access token claims. A serialized session owner provides existing currentUserID/freshIDToken/signOut capabilities, persisted Keychain tokens, singleflight refresh and stale-completion fences. Keep local account/E2EE storage and OCaml graph decisions unchanged. Request only openid. Remove native credential/challenge forms, SDK wrappers and package pins. No Dune/spec changes.

Reference: logseq/chat a136ba3fc02d3dd717cb5f097686f29ce2bfb36b, apple/Sources/LogseqChat/CognitoOAuth.swift and CognitoAuthProvider.swift. Local Chat 37c034e4 is obsolete. Journal owner authorized isolated branch from b36bea83. Source owner owns Swift auth/session; OCaml reducers cannot reproduce browser or token transport behavior, so tests target this public Swift boundary.

## Alternatives considered

### Retain Amplify native authentication

Conflicts with the user's explicit SDK removal. Embedded WebView and password grants are unnecessary and are excluded.

## Implementation

- Credential-free sign-in opens a system authentication session; cancel/error preserves account state and permits retry.
- Callback scheme/host/path/state/duplicates/expiry/replay are rejected before token transport. Concurrent refresh joins one request; sign-out retires in-flight work.
- Tokens use Keychain and validated issuer/audience/nonce/signature; account binding and E2EE contracts remain unchanged.
- No AWS SDK imports, wrapper or package pins remain. Swift and simulator compile, native owner tests and available repository checks pass.

## Consequences

- Existing SDK sessions require browser sign-in once; persisted local graph binding is retained.
- The same pool us-east-1_dtagLnju8, client 69cs1lgme7p8kbgld8n5kseii6 and domain logseq-prod.auth.us-east-1.amazoncognito.com are referenced by Chat. New logseqjournal://auth/callback must be confirmed registered and code flow enabled on the public no-secret client. No AWS configuration changes are authorized or performed.
- Synthetic tests cannot prove real Cognito sign-in, account recovery screens or system consent. Those need user secure handoff and GUI coordination. No device installation or personal graph access.


## Verification

- Formal public Swift session tests pass with an independent synthetic RS256 issuer. Coverage includes code/PKCE/state/nonce, callback scheme/host/path/duplicates/expiry/replay, issuer/audience/signature rejection, cold restoration, cached ID token, refresh singleflight and form escaping, network retry, invalid-grant clearing, sign-out and stale completion isolation. Cancellation during secure save was reproduced failing and now preserves the previous account, including cold restore.
- Existing platform service/account threading and lifecycle event tests pass. Native synthetic Simulator probe visibly passed initial sign-in, retryable error, busy/Cancel, Close and success dismissal. It used no real account, remote authentication, Keychain, graph or device.
- Complete current production Swift sources compile and link for iOS Simulator with only the owner-approved read-only LUI ee51 static library and OCaml object, without AWS objects. macOS authentication modules compile. Full macOS product remains blocked by unchanged baseline JournalChrome.swift:232 listSectionSpacing unavailable in macOS; it was reported to the consumer owner and not adapted here.
- Repository dune build passes. Force runtest initially passed 19 suites/445 cases and source boundary. Loopback TLS peer bind was sandbox-denied and an external-build repository-root lookup failed. The same sync suite (194 cases) passed with loopback permitted; the public compiler boundary (1 case) passed from the repository root using its external build symlink. Total coverage: 21 suites/640 cases. No Dune/spec/upstream edits.
- SwiftPM dependency graph contains only local LUI and no remote pins. Package.resolved and all AWS transitive pins are removed. Existing CryptoKit/Security, local-account binding and E2EE files remain unchanged. Spec-dev-tool check and diff whitespace checks pass.
- Real Cognito login, web recovery/challenges, production Keychain operations and OS consent remain untested. The exact new callback registration has not been verified; backend changes and real-account interaction are not performed.
