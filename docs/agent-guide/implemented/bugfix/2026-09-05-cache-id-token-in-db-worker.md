# Cache ID Token in DB Worker

## Problem

Catalog discovery, snapshot bootstrap, E2EE key access, and WebSocket connection all
use the same Cognito User Pool ID token as a bearer credential. The current design
nevertheless asks Core to classify every token request by network purpose and to wait
for a purpose-specific Flutter round trip before starting that operation.

Core stores only one `pending_token`. A later request replaces an earlier valid
request even when both operations belong to the same authenticated account. During a
cold start, catalog reconciliation can replace a pending snapshot-bootstrap request.
The snapshot token response is then rejected by correlation, no `/pull` starts, and
the app remains bootstrapping with a closed graph. The same race can suppress the
WebSocket request after a graph attaches.

Purpose classification does not protect a distinct credential or authorization
scope: every path asks Flutter for the same account ID token. It spreads
authentication-session ownership across pure Core, the DB Worker service protocol,
the Flutter application bridge, and each transport call. It also repeats host calls
that Amplify may answer with the same token and requires token-request scheduling to
be coordinated with otherwise independent graph lifecycle operations.

## Proposal

Make the DB Worker the single in-memory owner of the current authenticated account's
ID-token cache. Remove token-purpose classification and remove purpose-specific token
waiting from Core.

The cache contains:

- the authenticated account identity/generation that owns the entry;
- the raw Cognito ID token;
- the JWT `exp` instant; and
- a monotonic reuse deadline.

For a token acquired at time `now`, compute the reuse deadline as:

    min(now + 24 hours, token expiration - 1 hour)

The DB Worker may return the cached token directly only when the cache belongs to the
current authenticated account and the reuse deadline is still in the future. The
cache is process-local and must not be persisted to SQLite, preferences, files, or
Keychain. Raw token bytes must not appear in state snapshots, diagnostics, errors, or
logs.

If the cache is absent or no longer reusable, the DB Worker invokes one generic
Flutter ID-token capability. Flutter may generate a refreshed token or return an
already valid token through Amplify's authenticated session. The request and response
retain a challenge ID for correlation, but carry no catalog, snapshot, E2EE, or
WebSocket purpose.

Concurrent cache misses for the same authenticated account share one in-flight
Flutter request. When it completes, the DB Worker validates the response, verifies
that the account generation is still current, computes the reuse deadline, stores a
reusable entry, and resumes every still-current waiter. A token whose computed reuse
deadline is not in the future is not retained in the cache; if it has not actually
expired, it may satisfy the requesting operation once while the next operation asks
Flutter again.

Authenticated HTTP and WebSocket effects obtain an ID token from this DB Worker
provider at execution time. Their public requests no longer carry a raw token supplied
by Core. Catalog, snapshot, E2EE, and WebSocket state machines remain independently
scoped by their existing account, graph, connection, and lifecycle generations; only
credential acquisition is shared.

Sign-out, authenticated-account replacement, and worker shutdown clear the cache and
cancel or invalidate any in-flight Flutter request and its waiters. Graph selection,
graph replacement, and WebSocket reconnection do not clear the cache because the ID
token is account-scoped rather than graph-scoped. A delayed Flutter response for an
old account generation is discarded and cannot populate the replacement account's
cache.

When an authenticated HTTP request or WebSocket handshake returns `401`, invalidate
the cache entry used by that operation, obtain an ID token again through the same
cache-miss path, and retry the operation at most once. The retry must remain inside
the original operation scope and must not outlive its cancellation or generation.
Another `401` is returned as an authentication failure without a second refresh.
Treat `403` as an authorization failure: do not invalidate a still-reusable cache
entry and do not retry automatically.

Remove the obsolete token-purpose enum, Core `pending_token`, purpose-specific
`Token_requested`/`Token_provided` transitions, and token fields on authenticated
transport requests. Do not retain aliases or fallback paths for the old protocol.

## Decision

Adopt the DB Worker-owned, account-scoped, memory-only ID-token cache. Core no
longer schedules credential requests or carries raw tokens. Authenticated runners
acquire credentials at execution time, share concurrent misses, and apply the
bounded `401` refresh policy while preserving their existing operation scope.

## Alternatives considered

### Track multiple purpose-specific requests in Core

Core could replace its singleton with a map keyed by request ID, purpose, and
generation.

This would prevent direct overwrite, but it would preserve a classification that does
not correspond to different credentials. Every operation would still perform a host
round trip and pure Core would continue owning authentication scheduling that belongs
at the worker execution boundary.

### Keep the cache only in Flutter or Amplify

Amplify already manages its own authentication session and may reuse or refresh the
underlying ID token.

Relying only on that cache still requires one application-platform round trip for
every worker operation, still exposes token waiting to Core, and cannot coalesce
concurrent worker consumers before crossing the Flutter boundary.

### Store one cache per graph or transport

The Cognito ID token authenticates the user account, not one graph, HTTP request, or
WebSocket. Per-consumer caches duplicate the secret, create inconsistent expiration
behavior, and reintroduce coordination races.

### Persist the ID token across worker restarts

Persistence would extend the lifetime and attack surface of a bearer credential for a
small startup optimization. Flutter/Amplify remains the durable authentication owner;
the DB Worker cache is deliberately memory-only.

## Acceptance criteria

- Core has no `pending_token`, token-purpose enum, or purpose-specific token request
  transition.
- The DB Worker owns one memory-only ID-token cache for the current authenticated
  account and authenticated transports acquire their token through that cache.
- A cache hit returns the token without invoking Flutter.
- A cache entry is never reused later than 24 hours after acquisition or later than
  one hour before the JWT `exp` instant, whichever comes first.
- Missing, empty, malformed, oversized, expired, and account-stale token responses do
  not populate the cache and produce bounded, non-secret errors.
- Concurrent misses for one account invoke Flutter exactly once and resume all
  current waiters without coupling their graph lifecycle results.
- Sign-out and account replacement clear the entry and make a delayed old-account
  response inert; graph switching and WebSocket reconnection retain a valid
  account-scoped entry.
- An authenticated operation that receives `401` invalidates the token it used,
  obtains a token through the shared miss path, and retries at most once within its
  original scope. A second `401` is surfaced without another retry.
- A `403` response neither retries nor invalidates an otherwise reusable cache entry.
- No raw ID token is published through worker state, diagnostics, errors, or logs and
  no token is persisted outside process memory.
- Catalog, E2EE, snapshot, and WebSocket operations can start concurrently without
  replacing one another's authentication request.
- A cold start with an absent encrypted mirror reaches `/pull`, snapshot activation,
  graph attachment, and WebSocket connection without a lifecycle nudge.
- Deterministic clock tests cover a far-future token capped at 24 hours, a token
  capped at `exp - 1 hour`, an immediately non-reusable token, exact deadline expiry,
  concurrent misses, Flutter failure, sign-out, and account replacement.

## Risks

- The DB Worker now holds a bearer credential in memory for longer than one operation.
  The one-day and expiration-minus-one-hour bounds, strict account scoping, redaction,
  and lifecycle clearing are required security boundaries.
- JWT expiration uses wall-clock time while reuse should be measured monotonically.
  The implementation must derive a bounded duration from the observed wall clock and
  enforce it with the worker's monotonic clock so later wall-clock changes do not
  extend reuse.
- Incorrect miss coalescing can let cancellation of one consumer cancel every waiter,
  or let a stale completion populate a new account. The in-flight request needs its
  own account-generation identity and consumer-independent lifetime.
- A token returned within one hour of expiration may be usable once but intentionally
  provides no cache benefit. Flutter/Amplify is expected to refresh such a session;
  repeated near-expiry results must remain bounded and observable rather than loop.
- Moving credential acquisition below Core requires transport failures to retain the
  original operation scope without exposing the token or restoring removed
  purpose-specific protocol states.
- Automatic `401` recovery can duplicate a request if the server applied work before
  returning or the response was ambiguous. Only currently idempotent authenticated
  GET requests and the WebSocket handshake use this policy; any future mutating
  request requires its own replay-safety decision.

## Consequences

- Credential lifetime and invalidation are owned by one worker-session component
  instead of being distributed across Core, transports, and Flutter.
- Independent catalog, snapshot, E2EE, and WebSocket operations no longer replace
  one another's credential challenge.
- Flutter exposes one generic challenge/response capability, while raw token bytes
  remain below the pure reducer and are never persisted.
- Authenticated runner implementations must classify `401` and `403` distinctly so
  cache invalidation and retry behavior remain explicit.

## Questions

- None. The user approved one bounded cache-refresh retry for `401` and no retry for
  `403`.

## Implementation

The DB Worker effect runner now owns an account-generation-scoped token cache with
deterministic wall and monotonic clocks, bounded JWT validation, exact reuse
deadlines, coalesced misses, lifecycle cancellation, and token-specific
invalidation. The Bonsai service creates one cache per worker session and routes the
generic Flutter challenge response directly to it.

Sync Core no longer defines token purposes, pending token state, token events, or raw
token fields on authenticated effects. The Sync effect runner acquires credentials
through the DB Worker provider for catalog, snapshot, E2EE, and WebSocket work. HTTP,
snapshot download, and WebSocket handshake paths invalidate and retry once after
`401`; they surface a second `401` and never invalidate or retry after `403`.

The application bridge protocol now carries only `challengeId`. Obsolete purpose
decoding and compatibility paths were removed from both OCaml and Dart.

## Verification evidence

- DB Worker cache contract tests cover the 24-hour cap, `exp - 1 hour` cap, exact
  deadline expiry, immediately non-reusable tokens, malformed and stale responses,
  concurrent miss coalescing, Flutter failure, token-specific invalidation,
  sign-out, account replacement, and shutdown.
- Sync runner tests cover one `401` refresh, terminal second `401`, and non-retrying
  `403` behavior. Core contract tests cover the cold-start sequence from an absent
  mirror through snapshot activation, graph attachment, WebSocket connection, and
  `/pull` without an additional lifecycle event.
- Repository build, OCaml tests, Flutter tests, Flutter analysis, formatting, and
  whitespace checks pass.
- The macOS-only deployed managed-sync E2E passed against the production Cognito and
  sync endpoints with the configured encrypted graph. Sender and receiver sessions
  each completed catalog, snapshot/E2EE bootstrap, WebSocket synchronization, and
  authoritative mutation work with exactly one generic token challenge. The test
  now preserves that one-challenge-per-session requirement as a regression
  assertion without logging credential or token contents.
