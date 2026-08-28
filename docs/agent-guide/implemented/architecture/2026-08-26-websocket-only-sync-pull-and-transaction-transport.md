# Use WebSocket as the Only Pull and Transaction Transport

## Problem

The db-sync client currently exposes two transports for each authoritative sync
operation:

| Operation | WebSocket message | HTTP endpoint |
| --- | --- | --- |
| Pull remote transactions | `{"type":"pull","since":<t>}` | `GET /sync/<graph-id>/pull?since=<t>` |
| Submit local transactions | `{"type":"tx/batch",...}` | `POST /sync/<graph-id>/tx/batch` |

These are duplicate protocol entry points, not distinct product capabilities. Both
pull paths eventually decode `pull/ok` and apply the same ordered authoritative
replay. Both transaction paths submit the same `tx/batch` payload and consume the
same `tx/batch/ok` or `tx/reject` result. Maintaining both transports therefore
duplicates connection policy, authentication purposes, actions, completions,
generation fencing, state-machine branches, tests, and failure recovery without
adding a required offline capability.

The duplication is visible throughout the current client:

- `Sync_action` exposes `Http_pull`, `Transaction_submission`, `Fetch_http_pull`,
  and `Submit_http_transaction` in addition to WebSocket connect and send actions.
- `Sync_manager` contains HTTP-only transport states, token challenges, response
  events, disconnected submission routing, foreground fallback, and
  `recover_after_http_pull` coordination.
- The Bonsai service executes the two sync endpoints through `Sync_http` and feeds
  their responses back through `Http_pull_loaded` and
  `Http_transaction_loaded`.
- `Sync_protocol` has an HTTP-only pull decoder even though the response is already
  a normal `pull/ok` server message.
- The canonical action specification and host protocol expose the redundant HTTP
  purposes and effects.

The most consequential duplication is recovery policy. A failed foreground
WebSocket probe currently closes and fences the socket, performs HTTP catch-up, and
then opens another WebSocket. A disconnected local mutation may be submitted over
HTTP. This makes HTTP a fallback transport and permits pull or submission to have
different connection ownership and ordering from the WebSocket message stream.
The desired product rule is instead one authenticated, generation-fenced WebSocket
session for both operations. A failed socket must reconnect; it must not switch
protocols.

This exploration concerns only the duplicate sync pull and transaction endpoints.
HTTP remains in use for capabilities that do not have the selected WebSocket
equivalent, including catalog discovery, snapshot bootstrap and download, and E2EE
key access.

## Proposal

Make the graph WebSocket the only client transport for authoritative pull and
local `tx/batch` submission. Remove the HTTP alternatives completely rather than
retaining dormant actions, compatibility paths, feature flags, or fallback logic.

### One connection-ordered sync flow

Every graph connection follows one ordered flow:

1. Obtain a fresh ID token for `Websocket_connect` and open
   `ws(s)://<origin>/sync/<graph-id>`.
2. Send `hello` and one `pull` from durable `applied_server_t`.
3. Decode and apply `pull/ok` through the existing authoritative replay, cursor,
   checksum, pending-rebase, and invalidation path.
4. Mark the connection live only after the opening pull is applied successfully.
5. Pump durable local transactions as WebSocket `tx/batch` messages.
6. Treat `changed` and stale rejection as pull demand on that same connection.

Only one pull may be in flight for a connection generation because the upstream
messages do not carry a client pull request identifier. Concurrent causes are
coalesced into a single follow-up pull. Pull responses, transaction responses, and
control frames remain serialized through the existing frame-application owner.

`tx/batch/ok` changes pending acceptance state but does not replace authoritative
replay. Accepted writes are still confirmed through a later WebSocket pull, as they
are today.

### Queue local writes until WebSocket readiness

When there is no live WebSocket, a local transaction remains durably queued. The
client does not request a transaction-specific token and does not submit the batch
over HTTP. The pending pump starts only after the current WebSocket connection has
completed its opening authoritative pull.

A batch sent before a connection failure may have been accepted even if its
response was lost. Preserve the existing stable mutation ID and semantic recovery
model, but make recovery transport-neutral:

1. Record the uncertain submitted transaction IDs before fencing the failed
   connection generation.
2. Reconnect the WebSocket with bounded backoff.
3. Complete the opening WebSocket pull from durable `applied_server_t`.
4. Ask the engine to recover only those uncertain submitted IDs.
5. Replan each intent against the newly authoritative database. Remove a no-op
   intent; otherwise return it to the queue and resubmit it over the live WebSocket
   with the same stable mutation ID and the current cursor.

Rename HTTP-specific recovery state such as `recover_after_http_pull` to describe
the invariant, for example `recover_after_authoritative_pull`. Do not infer
acknowledgement by comparing raw outgoing and pulled transaction strings.

### Reconnect instead of falling back

WebSocket close, send failure, malformed frame, replay failure, checksum failure,
or foreground-probe timeout all use one recovery path:

1. Fence the failed connection generation and close its socket exactly once.
2. Preserve the readable local mirror, durable cursor, pending intents, and any
   uncertain submission descriptor.
3. Enter bounded reconnect backoff when the application is foregrounded; record
   deferred reconnect demand while it is backgrounded.
4. Open a new authenticated WebSocket and perform the normal `hello` plus opening
   `pull` sequence.
5. Recover uncertain submissions and resume the pending pump only after that pull
   applies.

Foreground revalidation keeps its pull-first behavior when the operating system
preserves a socket. A successful probe keeps the current connection generation. A
failed or timed-out probe reconnects through WebSocket; it never invokes HTTP
catch-up. A disconnected foreground resume likewise starts or resumes WebSocket
reconnection rather than issuing HTTP pull.

Failure to reconnect is non-blocking for an already populated graph. The local
timeline remains readable, sync reports its paused or reconnecting status, and
durable local edits remain queued until a WebSocket becomes live. There is no
secondary sync transport.

### Remove the redundant client surface

The implementation proposal should delete, rather than deprecate, the following
concepts from the client:

- `Http_pull` and `Transaction_submission` authentication purposes and their host
  protocol encodings;
- HTTP pull and HTTP transaction action payloads, constructors, and variants;
- `Http_pull_loaded` and `Http_transaction_loaded` manager events;
- `Awaiting_http_pull_token`, `Http_pull_in_flight`,
  `Http_catchup_applied`, and `Awaiting_http_submission_token` states;
- `Sync_http.pull` and `Sync_http.transaction_batch` execution paths;
- `decode_http_pull_response` and HTTP/WebSocket parity tests whose only purpose is
  to preserve the duplicate transport;
- endpoint construction for `GET /sync/<graph-id>/pull?since=<t>` and
  `POST /sync/<graph-id>/tx/batch`;
- fallback-oriented names, branches, fixtures, and diagnostics that imply HTTP is
  an available sync recovery path.

The remaining connection state should express only WebSocket lifecycle and
readiness, for example:

```text
Disconnected
AwaitingWebSocketToken
ConnectingWebSocket
CatchingUpWebSocket
LiveWebSocket
RevalidatingWebSocket
BackingOff
```

The existing background-suspension wrapper may preserve one of these states. Exact
constructor names are implementation details, but no state may represent HTTP pull
or HTTP transaction submission.

The canonical action specification under `spec/` must eventually remove the same
obsolete purposes, types, constructors, and smart constructors so production code
cannot reintroduce either endpoint. That specification change requires an explicit
implementation request under the repository rules; this exploring document does
not modify the specification.

### Decision-document impact

If proposed, this decision supersedes only the HTTP pull, HTTP transaction, and
HTTP fallback portions of these implemented decisions:

- `2026-08-21-login-sync-port.md`;
- `2026-08-22-ocaml-owned-sync-transport.md`;
- `2026-08-22-seamless-foreground-resume.md`;
- `2026-08-23-apple-platform-background-foreground-network-revalidation.md`.

Their local-first mirror, WebSocket ownership, lifecycle classification,
authoritative replay, cursor, checksum, pending-intent, E2EE, and generation-fence
decisions remain unchanged.

## Decision

Adopt the proposal in full. The graph WebSocket is the only authoritative pull and
local transaction-submission transport. Failed connections reconnect through the
same WebSocket lifecycle, durable writes wait for opening catch-up, and all HTTP
fallback contract and implementation paths are removed.

## Alternatives considered

### Keep HTTP as an automatic fallback

This preserves the current behavior after a failed foreground probe or disconnected
submission, but it retains all duplicate states, token purposes, endpoint code, and
ordering hazards. It directly contradicts the requirement that pull and
transaction submission use WebSocket without fallback.

### Prefer WebSocket while retaining unused HTTP code

Feature flags or unreachable compatibility branches would reduce immediate runtime
use of HTTP but keep two supported protocol surfaces. Later changes could silently
route around WebSocket again, tests would still need to preserve both paths, and
the action specification would continue to make the obsolete behavior valid. This
repository explicitly removes obsolete paths instead of maintaining compatibility
layers.

### Use HTTP only for background or foreground recovery

HTTP can provide a bounded request when no socket is live, but the application does
not currently perform background sync and already has durable local state. Waiting
for WebSocket reconnection preserves correctness with one transport. A separate
recovery transport is not worth the duplicate ownership and protocol policy.

### Make HTTP the only sync transport

This would remove duplication, but it would discard `changed` notifications,
connection-ordered responses, and the selected foreground sync protocol. It also
conflicts with the explicit choice of the WebSocket versions.

## Acceptance criteria

- Remote transaction catch-up sends
  `{"type":"pull","since":<applied_server_t>}` only over the current graph
  WebSocket and applies `pull/ok` through the authoritative replay path.
- Local transactions send `{"type":"tx/batch",...}` only over a live graph
  WebSocket.
- No production code constructs or calls
  `GET /sync/<graph-id>/pull?since=<t>` or
  `POST /sync/<graph-id>/tx/batch`.
- No action, event, authentication purpose, state constructor, host protocol value,
  or public contract exposes HTTP pull or HTTP transaction submission.
- A local transaction created while disconnected remains durable and unsent until
  opening WebSocket catch-up completes.
- Socket close, send failure, malformed response, replay failure, checksum failure,
  foreground-probe timeout, and reconnect-timer expiry never issue an HTTP sync
  request.
- A preserved foreground WebSocket is still revalidated by a WebSocket pull; a
  failed probe fences and reconnects the socket without HTTP catch-up.
- After an uncertain submission, the new WebSocket performs authoritative pull
  before semantic recovery and possible resubmission with the stable mutation ID.
- `changed`, connection-open catch-up, foreground revalidation, stale rejection,
  and post-acceptance confirmation retain one coalesced in-flight pull owner per
  connection generation.
- Catalog, snapshot, artifact, and E2EE HTTP capabilities continue to work and are
  not coupled to the removed sync endpoints.
- Deterministic manager and service tests cover disconnected queueing, reconnect
  catch-up, failed foreground revalidation, stale rebase, uncertain submission,
  graph switch, sign-out, background suspension, and late-frame generation fencing
  using WebSocket only.
- Repository searches and source-boundary tests reject reintroduction of the two
  HTTP sync endpoints and their obsolete symbols.
- `spec-dev-tool check --all` and all affected OCaml and Flutter test suites pass.

## Implementation evidence

- `Sync_action`, `Sync_auth`, `Sync_manager`, the Bonsai service interpreter, the
  engine protocol, the host protocol, and `spec/sync_action.mli` no longer expose
  HTTP pull or HTTP transaction submission.
- `Sync_http.snapshot_baseline` retains the cursor-free snapshot bootstrap request;
  no production constructor accepts a `since` query or constructs the removed
  transaction endpoint.
- Manager tests cover disconnected queueing, opening-pull readiness, reconnect and
  foreground-probe failure, malformed frames, replay failure, background
  suspension, coalesced pull demand, and uncertain submission recovery.
- Source-boundary tests reject all obsolete symbols, host values, the cursor query,
  and the transaction endpoint.
- `dune build`, the worker and top-level OCaml test suites, Flutter tests, Flutter
  analysis, and `spec-dev-tool check --all` complete successfully.

## Consequences

- Sync pull and transaction submission now have one ordering owner, one
  authentication purpose, and one connection-generation fence.
- Networks that permit HTTPS but block WebSocket traffic can no longer sync; the
  readable local mirror and durable pending queue remain available while reconnect
  is paused or backing off.
- A newly opened or background-preserved WebSocket is not ready for writes until
  its opening pull applies. Concurrent `changed`, stale rejection, foreground
  revalidation, and post-acceptance demand coalesce behind the single in-flight
  pull owner.
- The host protocol and canonical action specification cannot request HTTP pull or
  transaction-submission credentials or effects.
- Snapshot bootstrap continues to fetch its baseline over HTTP without exposing a
  cursor-based sync pull API. Catalog, snapshot artifact, and E2EE HTTP operations
  remain unchanged.
- Source-boundary tests reject reintroduction of the removed endpoint query,
  transaction endpoint, actions, events, states, purposes, decoders, and host
  values.

## Risks

- A server or network path that permits HTTPS requests but blocks WebSocket
  connections can no longer sync. This loss of transport diversity is intentional.
- Writes can remain queued longer during WebSocket outage because there is no
  disconnected HTTP submission path. The UI must continue to represent durable
  pending and paused states accurately.
- Reconnect must always perform authoritative pull before pumping pending writes;
  violating this ordering could submit against a stale cursor or mishandle an
  uncertain prior attempt.
- Removing HTTP-specific code touches the public action specification, host
  protocol, manager state machine, service interpreter, and a broad test surface.
  Partial removal could leave impossible states or misleading recovery behavior.
- A foreground probe timeout now pays WebSocket reconnect latency instead of using
  a bounded HTTP request. The local-first timeline prevents this from blocking
  reading, but visible sync recovery may take longer.

## Questions

None. The requested direction fixes the transport choice: both duplicated sync
operations use WebSocket exclusively, disconnected work waits for WebSocket
reconnection, and no HTTP fallback or compatibility path remains.
