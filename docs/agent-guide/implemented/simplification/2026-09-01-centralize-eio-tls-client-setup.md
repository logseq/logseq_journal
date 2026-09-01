# Centralize Eio TLS Client Setup

## Problem

The private `logseq_sync` effect runtime establishes the same TLS client flow in
two production modules:

| Surface | Production consumers | Repeated setup |
| --- | --- | --- |
| `logseq_sync/lib/effect_runner/eio/http_eio.ml` | `perform` and `download` | process-local RNG initialization, DNS host parsing, `http/1.1` TLS configuration, first-address lookup, socket connection, TLS wrapping, and cancellation preservation |
| `logseq_sync/lib/effect_runner/eio/websocket_eio.ml` | `connect` | the same setup |

Both modules independently own an `Atomic` initialization flag and call
`Mirage_crypto_rng_unix.use_default`. They also repeat `Domain_name` validation,
`Tls.Config.client`, port 443 defaulting, `Eio.Net.getaddrinfo_stream`, selection
of the first address, `Eio.Net.connect`, `Tls_eio.client_of_flow`, cancellation
re-raising, and exception-to-string conversion. The implementations differ only
where their protocols genuinely differ: HTTP accepts a previously validated
HTTPS request URI and has HTTP-specific failure text, while WebSocket validates
that its URI is WSS without credentials or a fragment and has WSS-specific
failure text.

The current duplicate setup is private implementation, not two supported
transport contracts. `Http_eio` and `Websocket_eio` are listed in
`private_modules` for `logseq_sync_effect_runner_impl`; their only production
consumer is the default `Effect_runner` dependency construction. The public
`Logseq_sync.Effect_runner` interface exposes injected transport operations, not
either private module. Tests exercise the public effect-runner boundary and the
repository's public-API-only testing decision explicitly forbids importing these
private modules merely to test them.

Maintaining two copies creates two apparent owners for TLS policy and currently
permits two separate one-time RNG guards in one runtime. A future change to DNS
selection, ALPN, TLS peer naming, cancellation, or RNG initialization can update
one transport while silently leaving the other behind.

## Proposal

Introduce one private Eio TLS-client helper inside
`logseq_sync_effect_runner_impl`. It owns exactly the behavior common to HTTP and
WebSocket connection establishment:

- one process-local, thread-safe initialization of the Mirage default RNG;
- conversion of a caller-supplied host string to a `Domain_name.host`;
- `Tls.Config.client` construction with the existing authenticator, peer name,
  and `http/1.1` ALPN value;
- first-address lookup for the caller-supplied host and port;
- socket connection and `Tls_eio.client_of_flow` wrapping; and
- re-raising `Eio.Cancel.Cancelled` while returning other connection failures as
  data.

Return a small private error variant for invalid DNS host, missing network
address, and transport exception. Let each caller map that variant to its exact
current public error string. This keeps `HTTPS host is not a valid DNS name`,
`sync host has no network address`, `WSS host is not a valid DNS name`, and
`WSS host has no network address` unchanged without passing presentation strings
into the shared transport helper.

Keep protocol-specific URI policy in its current caller. `Http_eio` continues to
own HTTP request validation, redirects, authority checks, headers, response
bounds, downloads, timeouts, and HTTPun adaptation. `Websocket_eio` continues to
reject non-WSS URLs, credentials, and fragments before connection setup and
continues to own the upgrade handshake, frame loops, message bounds, timeouts,
and close behavior. Do not create a generic HTTP/WebSocket transport abstraction
or move either protocol state machine.

Add the helper as a private module in the existing effect-runtime library and
delete the duplicated RNG, DNS, TLS, address, socket, and exception machinery
from both callers. This requires a narrow edit to
`logseq_sync/lib/effect_runner/dune` because that library uses an explicit module
list. The repository otherwise prohibits Dune edits without explicit user
authorization.

No OCaml file under `spec/`, public interface, wire value, redirect rule,
authentication purpose, timeout, effect order, error text, or sync state-machine
behavior changes. The current staged `logseq_db_worker` reducer/effect-runner
work is outside this decision.

## Decision

Adopt the proposal in full. The user explicitly authorized the one private
TLS-client helper and its narrow addition to the existing
`logseq_sync/lib/effect_runner/dune` module list on 2026-09-01. That authorization
does not extend to any other Dune, dependency, public interface, or library
boundary change.

## Alternatives considered

### Keep separate setup in each transport

This avoids a module and Dune change, but it retains two copies of
security-sensitive connection policy and two independent RNG initialization
guards. HTTP and WebSocket are distinct above the TLS flow, not at the repeated
DNS/TLS/socket layer.

### Make `Websocket_eio` call helpers exposed by `Http_eio`

This could avoid adding a module to Dune, but it would make WebSocket connection
setup conceptually depend on an HTTP implementation module. Exposing generic TLS
operations from `Http_eio.mli` would hide the real ownership problem behind a
misnamed dependency instead of creating one clear private owner.

### Centralize only RNG initialization

One RNG guard would remove the most obvious global duplication, but DNS parsing,
TLS configuration, address selection, socket connection, and cancellation
handling would still have two owners. The complete common setup is small and
behavior-identical enough to move together.

### Build a generic request/stream transport layer

HTTP request/response handling and WebSocket upgrade/frame handling have
different lifecycles and error policy. Abstracting both would relocate protocol
complexity into callbacks or a larger generic interface. The proposed boundary
stops at the common established TLS flow.

## Acceptance criteria

- Exactly one private effect-runtime implementation owns
  `Mirage_crypto_rng_unix.use_default`, its `Atomic` guard, DNS host conversion,
  `Tls.Config.client`, first-address resolution, `Eio.Net.connect`, and
  `Tls_eio.client_of_flow` for both HTTP and WebSocket clients.
- `Http_eio.perform`, `Http_eio.download`, and `Websocket_eio.connect` use the
  shared helper and retain no local copy of that setup.
- HTTP and WebSocket still default to port 443, select the first resolved
  address, use the supplied authenticator and DNS peer name, and advertise only
  `http/1.1` through ALPN.
- `Eio.Cancel.Cancelled` still propagates unchanged. All other connection
  exceptions still become the same `Printexc.to_string` error text.
- HTTP retains its exact missing-host, invalid-DNS-host, and no-address messages;
  WebSocket retains its exact URI-policy, invalid-DNS-host, and no-address
  messages.
- HTTP redirect/authority/content-type/download behavior and WebSocket
  authentication/upgrade/frame/close behavior remain unchanged.
- The helper is private to `logseq_sync_effect_runner_impl`; no public
  `Logseq_sync` API, `spec/` interface, wire contract, or test-only exposure is
  added.
- A source-boundary assertion prevents a second RNG/TLS client setup from
  returning without importing the private helper from tests.
- `dune exec logseq_sync/test/test_sync.exe`, `dune exec
  test/source_boundary_test.exe`, `dune runtest`, `dune build @all`, `dune build
  @fmt`, `git diff --check`, and `spec-dev-tool check --all` pass.

## Risks

- Mapping shared errors at the wrong layer could change exact HTTPS or WSS error
  text. The helper must return typed causes and leave caller-owned wording local.
- Moving WebSocket URI validation after the shared connection call could perform
  DNS or network work for a URL that is currently rejected first. Validation
  order must remain unchanged.
- A shared RNG guard changes the current possibility of calling
  `Mirage_crypto_rng_unix.use_default` once from each transport to one call for
  the effect runtime. This is the intended removal of duplicate global setup,
  but implementation must confirm that the library contract treats repeated
  initialization as unnecessary rather than transport-scoped state.
- The public-API-only test boundary prevents direct unit tests of the new helper.
  Preservation evidence must come from existing public effect-runner tests,
  source-boundary assertions, the full build/test suite, and exact caller-side
  error mappings.
- Adding a correctly named private module requires the narrowly authorized Dune
  edit called out in the decision. Implementation must keep that edit limited to
  the private module list and must not use it to change dependencies or public
  library structure.

## Consequences

`Tls_client_eio` now owns the single process-wide RNG guard and the shared
DNS/TLS/socket connection path. Its private error type distinguishes an invalid
DNS host, an empty address result, and a setup failure. `Http_eio` and
`Websocket_eio` map those causes to their existing protocol-specific strings and
retain their original URI validation, timeout, redirect, handshake, frame, and
cleanup behavior.

The helper is present in both the explicit module list and `private_modules` for
`logseq_sync_effect_runner_impl`. No dependency, public library, `spec/`
interface, wire contract, or test-only import changed. A source-boundary test
requires the helper, exact caller-owned errors, and one low-level TLS setup owner
while forbidding those operations from returning to either caller.

Implementation completed on 2026-09-01. The focused source-boundary test and all
53 `logseq_sync` tests passed before and after formatting. `dune runtest`, `dune
build @all`, `dune build @fmt`, and `git diff --check` also passed against the
complete worktree.

## Questions

- None.
