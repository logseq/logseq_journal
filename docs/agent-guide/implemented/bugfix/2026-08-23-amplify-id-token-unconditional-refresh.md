# Amplify Id Token Unconditional Refresh

## Problem

Every sync authentication challenge calls `Amplify.Auth.fetchAuthSession` with
`forceRefresh: true`. On the signed physical iPhone, the cached Cognito session is
valid and authenticated API requests using its ID token succeed, but the forced
refresh POST is closed before receiving a complete HTTP response. The application
therefore enters `ID token acquisition failed` before catalog discovery even though
the device network and current ID token are usable.

The local Amplify 2.15.0 implementation already checks access-token and ID-token
expiration when `forceRefresh` is false. It refreshes invalidated tokens and tokens
that expire within ten seconds. Setting `forceRefresh` ignores that cache decision
and requests newly issued tokens for every catalog, E2EE, HTTP pull, WebSocket, and
transaction challenge. That creates an unnecessary Cognito dependency on every
sync operation and prevents physical-device foreground validation.

## Decision

Fetch the current Amplify auth session once per manager challenge without
`forceRefresh`. Continue validating that the session is signed in, has Cognito user
pool tokens, and contains a bounded non-empty ID token before returning it to the
OCaml manager.

Amplify remains the sole token cache and refresh owner. The application does not
cache tokens itself and does not catch a failed refresh to reuse an expired token.
When the cached session is expired, nearly expired, or invalidated, Amplify performs
its normal refresh and propagates a failure if that refresh cannot complete. The
manager still requests a valid token independently for each authenticated network
effect; "fresh" means freshly obtained from the auth capability for that challenge,
not forcibly reissued by Cognito.

## Implementation evidence

The production auth capability now calls `Amplify.Auth.fetchAuthSession()` without
overriding its expiration-aware refresh policy. A source-boundary regression test
prevents reintroducing unconditional force refresh.

On the signed physical iPhone, the same stored session that previously entered
`ID token acquisition failed` completed catalog discovery, E2EE key retrieval,
authoritative graph pull, and journal rendering after this change.

## Alternatives considered

### Force refresh every challenge

Rejected because it ignores Amplify's expiration-aware cache, adds a Cognito POST
before every sync operation, and reproduces the physical-device failure.

### Retry with the cached token after forced refresh fails

Rejected because the application would need to decide whether a cached token is
still valid after an auth failure. That duplicates Amplify's session policy and can
accidentally reuse an expired or invalidated token.

### Cache one token in the sync manager

Rejected because token storage and expiration remain platform-auth concerns. The
manager should retain challenge and generation ownership without receiving token
cache responsibility.

## Acceptance criteria

- Production ID-token acquisition does not set `forceRefresh: true`.
- One manager challenge still performs one platform auth-session request and returns
  one validated ID token.
- Amplify remains responsible for refreshing expired, nearly expired, or invalidated
  sessions; no application fallback returns a token after refresh failure.
- The signed physical-iPhone app passes catalog discovery using the current valid
  session and can continue into the E2EE graph flow.

## Consequences

- A still-valid cached token may be returned for multiple challenges until Amplify's
  expiration policy decides it requires refresh. The API must continue to accept
  standard Cognito token validity rather than requiring a newly issued token for
  every request.
- Revocation that does not invalidate local Amplify state may first appear as an API
  authentication failure. Existing sign-out and auth-hub events remain responsible
  for explicit session invalidation.

## Questions

None.
