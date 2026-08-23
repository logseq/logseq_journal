# Apple Platform Background and Foreground Network Revalidation

## Problem

Logseq Journal currently treats every Flutter `AppLifecycleState.resumed` event as
a reason to replace the active sync transport. The Flutter host emits a fresh
calendar event for every `resumed` callback without remembering whether the app
previously reached `hidden` or `paused`. The application converts that calendar
event into `Foreground_resumed`, and the sync service cancels all graph-bound
network operations before the sync manager handles the command. The manager then
fences and closes the existing WebSocket, performs an authenticated HTTP pull from
the durable server cursor, and reconnects a new WebSocket with another fresh token.

This behavior has four problems.

First, `inactive` is not equivalent to background on iOS. The app can become
inactive while remaining visible and runnable, for example during a system overlay,
authentication prompt, or app-switcher transition. An `inactive -> resumed`
transition currently performs the same network replacement as a real
`paused -> resumed` transition.

Second, forcibly cancelling the graph network scope and then separately closing the
WebSocket gives two owners responsibility for terminating the same transport. The
resulting cancellation and writer-close race can surface aggregated exceptions such
as `Network_cancelled` and `cannot write to closed writer` when the app returns to
the foreground.

Third, replacing a healthy WebSocket adds an HTTP request, two ID-token challenges,
and a complete reconnect even when the operating system preserved the original
socket during a short background interval. A successful WebSocket send alone cannot prove that the
connection is usable, but the existing sync `pull`/`pull/ok` exchange can validate
both transport liveness and graph cursor continuity.

Fourth, transport uncertainty intersects with durable local writes. The engine
persists a selected outgoing batch as `Submitted` before the transport sends it.
Within one engine lifetime, a submitted batch is not emitted again unless the
server returns an explicit response. Engine startup recovers `Submitted` entries to
`Queued`, but foreground revalidation does not. If suspension interrupts a batch
after submission and before its response, the server may or may not have accepted
it, and the current runtime has no bounded recovery path for the unresolved batch.

The existing seamless-foreground-resume decision preserves visible journal state,
but intentionally retains the close, HTTP pull, and reconnect handshake. This
exploration concerns the network lifecycle for an already-open synced graph. It
does not add iOS background replay, background execution entitlement, or a new sync
wire message.

## Proposal

Adopt the same lifecycle-aware network quiescence and pull-first foreground
revalidation state machine on iOS and macOS. Separate application visibility from
transport readiness so that a preserved WebSocket is treated as uncertain, not
immediately healthy or immediately dead, after a real background interval.

The foreground probe deadline is three seconds measured with a monotonic clock from
dispatch of the revalidation pull. A send or protocol failure may start fallback
earlier. Deterministic tests should use a fake clock.

iOS and macOS use the same semantic state transitions and sync effects. Their native
lifecycle callbacks may differ, but both platform adapters must classify those
callbacks into the same foreground, inactive, backgrounded, and detached meanings
before emitting lifecycle events to the sync manager.

### Classify lifecycle transitions semantically

The Flutter host should remember whether the current lifecycle epoch reached
`hidden` or `paused`.

- `inactive` does not change sync network state.
- The first `hidden` or `paused` event in an epoch emits one background signal and
  marks the epoch as backgrounded.
- `resumed` emits foreground network revalidation only when the epoch was previously
  marked backgrounded.
- Repeated `hidden`, `paused`, or `resumed` callbacks in the same epoch are
  coalesced.
- Initial startup at `resumed` follows the existing bootstrap path and is not a
  foreground revalidation.
- `detached` and process termination rely on durable state and the existing cold
  start path rather than attempting last-moment network recovery.

Calendar freshness and network lifecycle should no longer share one overloaded
event. A fresh calendar snapshot remains necessary on every `resumed` callback for
local-day, locale, time-zone, and UTC-offset classification. Only a typed network
resume event for a completed background epoch should reach the sync manager.

### Quiesce foreground-only network work while backgrounded

Entering `hidden` or `paused` should move an open graph into a background-quiescent
state without proactively cancelling or closing its WebSocket. The app must not
assume that the socket will survive, but it should preserve the transport object so
that foreground revalidation can reuse it when it does survive.

While backgrounded, the manager should not start any new HTTP pull, reconnect,
token challenge, or pending transaction pump. A reconnect timer that elapses while
backgrounded records deferred reconnect demand but produces no network effect until
the app resumes. Existing durable cursor, checksum, authoritative mirror, pending
intents, selected graph, runtime, and presentation state remain intact.

Operations already in flight when the app becomes backgrounded follow one ownership
policy:

- a current-generation read-only HTTP pull is not cancelled, and its result may
  still be applied by the serialized owner;
- an HTTP or WebSocket transaction submission remains recorded as in flight and is
  not resubmitted while backgrounded;
- after a preserved WebSocket passes foreground revalidation, ordered responses
  already on that connection, including `tx/batch/ok`, are processed before the
  revalidation `pull/ok` completes;
- after foreground revalidation fails, the manager fences the old connection,
  completes authoritative HTTP catch-up, and explicitly requeues any transaction
  attempt that remains unresolved;
- token challenges, reconnect timers, and reconnect demand become deferred state and
  produce no background network operation;
- the manager state machine is the only owner allowed to cancel or close a graph
  transport. The service loop must not pre-cancel the graph network scope before the
  manager selects the transition and effects.

This is network quiescence, not background sync. The process may be suspended or
terminated at any time, and correctness must continue to depend on durable state.

### Revalidate a preserved WebSocket with sync `pull`

When an already-open graph resumes from a background epoch and its WebSocket has not
reported closure, the manager should enter an explicit `Revalidating` state. It
must not increment `connection_generation`, cancel the graph network scope, close
the socket, or request a token before attempting the probe.

The manager sends exactly one sync `pull` from durable `applied_server_t` on the
existing WebSocket. It then waits for the current connection generation to produce
a valid `pull/ok` that the serialized graph engine successfully applies. Enqueueing
or writing the request is not success. A WebSocket control `pong` would prove less
than this exchange because it would not validate authentication, sync protocol
handling, cursor continuity, checksum, or authoritative catch-up.

The successful path is:

1. Send `pull(since = applied_server_t)` on the preserved WebSocket.
2. Decode `pull/ok` through the existing sync protocol decoder.
3. Apply it through the existing authoritative replay, cursor, checksum, pending
   rebase, and graph invalidation path.
4. Mark the same connection generation `Live` only after the engine reports a
   successful `Sync_applied` result for the in-flight revalidation.
5. Resume the pending transaction pump after the connection becomes `Live`.

The manager should serialize pull ownership per connection. `changed`, `hello`,
connection-open catch-up, stale-rejection recovery, and foreground revalidation can
all request a pull, but only one pull may be in flight on a connection. Additional
causes are coalesced into desired catch-up work. This is necessary because the
current wire protocol has no client request identifier with which to correlate
multiple concurrent `pull/ok` responses.

### Use one bounded fallback after probe failure

A three-second foreground revalidation deadline, WebSocket close, send failure,
protocol decode failure, replay pause, or checksum failure makes the preserved connection unusable.
The fallback should have a single owner and execute once:

1. Fence the old connection by incrementing `connection_generation`.
2. Cancel the old generation's network operations and close the WebSocket once.
3. Request a fresh ID token and perform HTTP pull from durable
   `applied_server_t`.
4. Apply the HTTP response through the same serialized authoritative replay path.
5. Request another fresh ID token and connect a new WebSocket.
6. Send the normal `hello` and connection-open pull before marking the transport
   live and pumping pending writes.

Late frames and completions from the fenced connection must be ignored by generation.
If HTTP pull or reconnect fails, the populated graph and timeline remain available,
sync enters its existing non-blocking paused/error state, and retry uses bounded
backoff. The manager must never return to the unvalidated old WebSocket after the
fallback starts.

### Distinguish socket presence from transport readiness

The current `websocket_open : bool` is insufficient because a socket can be present
while it is being revalidated. The transport state should make invalid combinations
unrepresentable, for example:

```text
Disconnected
Connecting(connection_generation)
Live(connection_generation)
Suspended(connection_generation, socket_present)
Revalidating(connection_generation, durable_cursor, lifecycle_generation)
Http_catching_up(connection_generation)
Backing_off(connection_generation, deferred_reason)
```

Pending batches may use WebSocket transport only in `Live`. A batch produced during
`Suspended` or `Revalidating` remains durable and waits. HTTP transaction submission
remains available for the existing disconnected foreground path, but background
state must not start it.

### Recover transport-uncertain submitted writes

Foreground recovery must distinguish a durable intent from a particular transport
attempt. A stable mutation ID remains the transaction ID across all attempts.

An authoritative `pull/ok` transaction has server `t`, Transit `tx`, and optional
`outliner-op`, but no explicit client `tx-id`. The client must not infer
acknowledgement by comparing raw transaction strings because the server may expand
a cardinality-one update into retract and add datoms, append server transaction
entity IDs, and use Transit cache references. Instead, recovery reconciles the
durable mutation intent semantically by replanning it against the authoritative
database after catch-up.

Transport-attempt ownership and durable intent ownership should remain separate:

- the manager owns the in-memory transport attempt, including connection generation,
  lifecycle generation, batch transaction IDs, send state, and expected response;
- the engine owns durable `Queued`, `Submitted`, `Accepted`, and `Blocked` entries and
  is the only component allowed to change those entries;
- when a transport attempt becomes uncertain, the manager first fences the old
  generation and completes authoritative catch-up;
- after authoritative catch-up, the manager sends one explicit serialized engine
  command identifying the unresolved transaction IDs that return from `Submitted`
  to `Queued`;
- the engine replans retryable intents against the latest authoritative database;
- if replanning produces no operations, the authoritative state already satisfies
  the intent, so the engine removes the pending entry without sending another
  batch;
- if operations remain, the engine regenerates the transaction against the current
  database and resubmits it with the original stable client transaction ID.

This does not require persisting connection generations on pending entries. If the
process survives, the manager still owns the attempt descriptor. If it terminates,
engine startup already recovers all `Submitted` entries to `Queued`. That existing
startup behavior also assumes that retrying the same stable transaction ID is safe.
The deployed validation below confirms that an exact old-cursor repeat does not
apply twice, while also showing that its generic stale response is not sufficient
to resolve a specific pending entry.

The selected recovery direction is therefore to requeue an unresolved `Submitted`
entry only after authoritative catch-up. A no-op replan resolves an already accepted
attempt locally. A non-empty replan represents an intent that authoritative state
does not yet satisfy and is safe to send with the same stable client `tx-id` and the
current server cursor. A generic `stale` response never resolves a specific pending
entry by itself; it only requests another authoritative pull.

This ordering prevents an uncertain foreground transition from immediately sending
a second copy before learning whether the first copy was accepted. It also provides
a bounded replacement for the current behavior in which an unacknowledged
`Submitted` entry remains stuck until engine restart. Recovery must be explicit and
testable rather than inferred from socket booleans.

### Deployed-server uncertain-submission evidence

The deployed behavior was verified on 2026-08-23 against the isolated
`ocaml-sync-test` graph. The sanitized capture is stored in
`logseq_db_worker/test/fixtures/sync/deployed-duplicate-tx-id-stale.json`.

1. At server cursor `114`, the first batch used client tx-id
   `10eaff77-c413-4a4e-ad05-3861f1cba40e`.
2. The server accepted it as `tx/batch/ok` at cursor `115` with checksum
   `a57d8ae9dc79e209`.
3. Repeating the exact original batch with the same old `t-before`, transaction, and
   client tx-id returned `{"type":"tx/reject","reason":"stale","t":115}`.
   It returned no checksum, successful IDs, failed ID, data, or tx-id conflict.
4. A final pull from cursor `114` returned exactly one transaction at cursor `115`
   and the same checksum. The repeated request did not apply a second mutation or
   advance server state.
5. The pulled transaction was server-normalized into retract and add datoms, so raw
   outgoing/pulled transaction equality is not a valid reconciliation mechanism.

This result disproves the earlier expected tx-id-conflict response. The generic
stale rejection prevents that exact old-cursor request from executing twice, but it
does not identify which client transaction was accepted. Correct recovery therefore
depends on authoritative intent replanning, not error-string classification.

### Implementation status

The shared Apple lifecycle adapter and sync manager now implement the proposed
pull-first path. The manager keeps an already-open WebSocket across a background
epoch, sends one foreground pull with a three-second deadline, and preserves the
connection generation after successful replay. Timeout, close, send failure,
protocol decode failure, and replay pause use one transport-fencing helper before
HTTP catch-up. The service no longer closes a WebSocket before the manager selects
the transport action.

HTTP pull and transaction effects and completions now carry the connection
generation. A late completion from a fenced attempt is ignored even when account
and graph generations still match. Transport readiness is represented by one
closed state machine: `Foreground_transport` or `Suspended` wraps exactly one of
`Disconnected`, `Awaiting_websocket_token`, `Connecting_websocket`,
`Live_websocket`, `Revalidating_websocket`, `Awaiting_http_pull_token`,
`Http_pull_in_flight`, `Http_catchup_applied`, or `Backing_off`. The obsolete
readiness booleans have been removed. Separate typed pull-ownership and
frame-application states prevent duplicate pulls and prevent an HTTP transaction
acknowledgement from being misclassified as completion of authoritative HTTP
catch-up. ID-token acquisition failure for an already-populated graph now preserves
the graph in `Sync_paused` and enters bounded reconnect backoff; a failure delivered
while suspended records deferred retry demand without starting background network
work.

The manager preserves the first unresolved transaction attempt while later durable
pending batches remain queued in the engine. After failed-probe HTTP catch-up, only
the transaction IDs from that uncertain attempt are explicitly returned from
`Submitted` to `Queued`; the engine remains responsible for semantic replanning and
stable mutation-ID reuse.

Physical macOS validation also exposed a deployed presence message with type
`online-users`. The upstream server
[broadcasts this message when graph presence changes](https://github.com/logseq/logseq/blob/master/deps/db-sync/src/logseq/db_sync/worker/presence.cljs#L35-L37). The
sync protocol now validates its `online-users` array and the manager ignores the
presence event without sending it to the authoritative graph engine or changing a
foreground probe. Malformed presence payloads remain protocol errors.

Deterministic regression coverage now includes immediate fallback for malformed,
closed, replay-failed, and paused probes; stale HTTP completion fencing; preservation
of an in-flight HTTP pull across background and foreground; exact uncertain-write
recovery; prevention of pending-attempt replacement; HTTP transaction and pull
interleaving; presence interleaving; and manager-only WebSocket shutdown ownership.
It also covers HTTP-pull and WebSocket-reconnect token failures in foreground and
background states.

### Physical-device validation status

On 2026-08-23, a signed physical iPhone completed authenticated catalog discovery,
E2EE graph open, authoritative pull through cursor 115, and populated journal
rendering. The same running process was activated, sent to the background by
activating Settings, and reactivated after a short interval. The timeline remained
populated and no `Multiple exceptions`, `Network_cancelled`,
`cannot write to closed writer`, authentication, E2EE, or sync protocol error was
observed after foreground return.

The updated build additionally completed a 45-second iPhone background interval and
a process-termination test in which the app was backgrounded, terminated, rebuilt,
and cold-started against the existing durable mirror. No `Multiple exceptions`,
closed-writer, E2EE response-contract, presence, or sync protocol error was observed
in the attached Flutter console.

The physical iPhone then completed a genuinely offline foreground cycle while the
Mac remained connected as an independent USB controller. The running app first
rendered its populated timeline, entered the background, and had Airplane Mode
enabled with Wi-Fi disabled before it returned to the foreground. The same process
remained alive, the timeline stayed readable, and the expected non-blocking
`Sync_paused` banner appeared without `Multiple exceptions`, `Network_cancelled`,
closed-writer, or process-termination output. Network restoration used Control
Center while the app remained foreground-visible, so Flutter traversed only
`inactive -> resumed`; it did not receive another background epoch with which to
restart recovery. Bounded retry cleared the banner after 8.44 seconds, and the
timeline remained accessible. A follow-up Settings probe confirmed that Airplane
Mode returned to Off. This proves that recovery does not depend on a second
background-to-foreground transition.

The physical iPhone finally completed a deployed server-originated close test
against a newly created disposable synced graph named
`codex-ws-close-test-20260823`. The app selected the graph and rendered its empty
timeline before deletion. An independent authenticated WebSocket observer connected
to the same graph, after which the authenticated `DELETE /graphs/:graph-id` request
returned HTTP `200` with `deleted: true`. The observer received a clean close with
code `1000` and reason `graph deleted`; the CLI connection to the same graph also
changed from `open` to `closed`. The iPhone app remained in the same process, kept
the empty timeline operable, and exposed only the non-blocking
`sync HTTP request failed with status 403` banner. The `403` is expected because the
server removes graph access before the close-path HTTP catch-up can run. No
`Multiple exceptions`, closed-writer, exception, or abnormal process-termination
output appeared. The remote catalog and the CLI graph list were both checked after
cleanup and no longer
contained the disposable graph. The existing `ocaml-sync-test` graph was not
modified.

The same build completed a visible macOS foreground cycle with its populated
timeline preserved. The first macOS run exposed the valid `online-users` presence
message described above; after the protocol fix and rebuild, the foreground cycle
completed with no visible sync error and no console exception.

A second macOS validation used the already-running local network proxy to terminate
only connections whose destination host was `api.logseq.io`. The app first entered
the background, then returned to the foreground while the proxy terminated every
replacement connection for twelve seconds. Nine sync-endpoint connections were
terminated, the endpoint had zero live connections at the observation point, and
the Codex control connection and the rest of the Mac network remained available.
The populated timeline stayed readable. During the outage the app exposed its
existing non-blocking `Sync_paused` banner with
`sync HTTP protocol failed: malformed HTTP response`; it did not delete or reset the
local mirror. After the endpoint intervention stopped, bounded retry established two
new connections and cleared the banner without user action or process restart.

An attempt to disable the Mac Ethernet service moved the default route from `en0`
to `en1`, confirming that the interface change occurred, but the same Mac network is
also the Codex control plane. A complete interface-switch or system-offline test
cannot be driven reliably by this task because loss of that route also removes the
controller that must observe and restore the test. Ethernet and Wi-Fi were restored
to enabled state and the default route returned to `en0` before continuing. This is
an automation-environment limitation, not evidence that a genuine system-offline
resume passed.

Deterministic manager tests separately verify the server-closed, timeout, malformed,
replay-failed, offline/backoff, and stale-generation branches. The targeted proxy
test now also verifies real transport loss, foreground endpoint unavailability, and
automatic recovery on the macOS build without taking the task controller offline.
The independently controlled iPhone now covers a real interface shutdown, genuine
offline resume, foreground-only automatic recovery, and a deployed clean server
close followed by authoritative fallback. Together with the short-background,
process-termination, and macOS transport-loss tests above, all required physical
scenarios are covered.

## Decision

Use one lifecycle-aware sync policy on iOS and macOS. Native and Flutter lifecycle
signals are normalized into semantic epochs: `inactive` never changes network
state, the first `hidden` or `paused` event suspends new network work, and one
subsequent `resumed` event revalidates the current transport. Duplicate callbacks in
the same epoch are coalesced.

Preserve an existing WebSocket across background entry. On foreground return, send
one sync `pull` from the durable cursor over that socket and allow three seconds for
the serialized `pull/ok` replay to complete. A successful replay returns the same
connection generation to `Live`; pending submissions remain deferred until then.
Do not add a separate application ping/pong capability.

On probe timeout, close, send failure, malformed response, replay pause, or checksum
failure, fence the old connection generation exactly once, close it through the
sync manager, perform authoritative HTTP catch-up, recover only unresolved
`Submitted` transaction IDs through an explicit engine command, and reconnect with
a fresh token. Replanning against the authoritative database determines whether a
stable client transaction ID resolves locally as a no-op or needs resubmission.

Represent transport and pull ownership with closed state machines rather than
independent readiness booleans. The sync manager is the sole graph transport close
and cancellation owner; the service loop executes its effects but does not
pre-cancel lifecycle work. Accept and ignore valid deployed `online-users` presence
messages without allowing them to complete or fail a foreground probe.

## Alternatives considered

### Always close, HTTP pull, and reconnect

This was the previous behavior. It gave every foreground transition an authoritative
HTTP boundary, but performs unnecessary authentication and transport replacement,
misclassifies `inactive -> resumed`, and creates competing cancellation and close
paths. Keeping it would require fixing the cancellation race but would not provide
seamless transport reuse.

### Trust a preserved socket without a probe

Socket presence and the absence of a close callback do not prove that the
connection survived suspension. The first user mutation could otherwise become the
liveness test. This creates avoidable uncertainty for writes and does not catch up
remote changes before pending submission.

### Add application-level ping/pong

The decoder recognizes a sync `pong`, and the WebSocket transport handles incoming
control ping frames, but the client has no complete outgoing ping/deadline protocol.
Adding one would only test connection responsiveness. Existing `pull`/`pull/ok`
provides the stronger semantic guarantee required by foreground sync and avoids a
new wire capability.

### Start HTTP pull and WebSocket pull in parallel

Racing both paths may reduce the slowest recovery latency, but it introduces two
authoritative responses, token work on the healthy path, more complex pull
correlation, and competing transport ownership. A bounded sequential fallback is
simpler and preserves one serialized owner for graph state.

### Reconnect immediately but skip HTTP pull

A new WebSocket can perform the normal connection-open pull, but reconnect still
throws away a healthy socket and requires a fresh token. It also does not solve the
duplicate lifecycle signal or uncertain submitted-write problem.

### Continue network pumping in background

The shared Apple-platform policy intentionally does not depend on background
execution. Starting reconnect, HTTP catch-up, or transaction submission during a
background interval creates operations that may be suspended or deprioritized at
arbitrary points. Background replay and additional platform execution capabilities
are outside the current architecture decision.

## Acceptance criteria

- `inactive -> resumed` refreshes calendar facts but produces no sync lifecycle
  command, token request, HTTP request, WebSocket close, or reconnect.
- One `hidden/paused -> resumed` epoch produces one foreground network revalidation.
- A preserved live WebSocket receives exactly one pull from the durable cursor and
  remains on the same `connection_generation` after a valid duplicate `pull/ok`.
- A foreground pull containing remote changes uses authoritative replay and graph
  invalidation before the same socket returns to `Live`.
- Pending transactions are not sent while the transport is `Suspended` or
  `Revalidating` and resume only after successful catch-up.
- Concurrent `changed`, `hello`, stale-recovery, connection-open, and foreground
  pull demand never creates more than one in-flight pull per connection.
- Probe timeout, send failure, close, malformed response, replay pause, and checksum
  failure each trigger one fenced close, one HTTP catch-up sequence, and one fresh
  WebSocket reconnect sequence.
- A late `pull/ok`, close callback, HTTP completion, or timer from an obsolete
  connection generation cannot mutate current manager or engine state.
- A reconnect timer that elapses while backgrounded performs no network operation
  and is resumed or superseded exactly once after foreground return.
- A current-generation read-only HTTP pull already in flight at background entry is
  not cancelled and may complete through the serialized graph owner.
- In-flight HTTP and WebSocket transaction submissions are not duplicated while the
  app is backgrounded.
- A successful preserved-WebSocket probe processes an earlier ordered
  `tx/batch/ok` before treating its later `pull/ok` as completion of revalidation.
- A failed probe fences the old attempt before authoritative HTTP catch-up and
  requeue of unresolved submitted entries.
- The manager is the sole graph transport cancellation and close owner; lifecycle
  handling in the service loop does not independently pre-cancel the network scope.
- After authoritative catch-up, an unresolved `Submitted` entry returns to `Queued`
  while preserving its stable client `tx-id`.
- If authoritative state already satisfies that intent, recovery removes the
  pending entry and emits no transaction batch.
- If authoritative state does not satisfy that intent, recovery regenerates a
  non-empty transaction against the current cursor and resubmits it with the same
  stable client `tx-id`.
- Replaying the captured exact old-cursor batch returns the deployed generic stale
  response and does not advance server state with a duplicate mutation.
- A submitted batch that was not accepted becomes retryable after the old transport
  is fenced and authoritative catch-up completes, while preserving its stable
  transaction ID.
- Foreground revalidation and every failure path preserve the existing graph,
  timeline, route, drafts, and durable pending intents.
- Cold start after the operating system terminates the backgrounded process continues to recover
  durable submitted entries and perform normal bootstrap.
- Physical-iPhone and macOS tests cover a short background interval with a preserved
  socket, a server-closed socket, a network-interface change, offline resume, and
  process termination where supported.

## Risks

- Waiting for the WebSocket probe adds up to three seconds before falling back to
  HTTP when the operating system has silently invalidated the socket.
- A `pull/ok` response cannot be correlated by request ID. Correctness depends on
  serializing all pull demand per connection and matching connection and lifecycle
  generations.
- Preserving a WebSocket object does not extend iOS background execution and must
  not be presented as background connectivity.
- The deployed server's generic stale response contains no client tx-id, checksum,
  or acceptance evidence. The client must preserve the authoritative-pull-first
  ordering and must never classify that response as acknowledgement of a specific
  mutation.
- Replacing boolean transport flags with a typed state machine touches manager,
  service-loop, engine coordination, and tests even though no sync wire change is
  intended.
- A platform can omit lifecycle notifications if the process is killed.
  Durable state and cold-start recovery therefore remain mandatory.
- Applying one semantic state machine to iOS and macOS requires platform lifecycle
  adapters to normalize different native callback sequences without changing sync
  policy.

## Consequences

- A short background interval normally reuses the existing WebSocket and needs only
  one semantic pull, avoiding an HTTP request, a replacement socket, and two fresh
  token challenges.
- A silently invalid socket may add up to three seconds before HTTP fallback. Every
  fallback then uses a new connection generation, so late frames, timers, and HTTP
  completions cannot mutate the current graph.
- Background state starts no reconnect, transaction submission, or new pull work.
  This decision does not add an iOS background-execution entitlement or promise
  background connectivity.
- Uncertain durable writes now have a bounded recovery path within one process.
  Recovery preserves stable client transaction IDs but depends on authoritative
  semantic replanning rather than server error strings or raw transaction equality.
- Transport correctness is concentrated in the OCaml sync manager and engine. The
  additional typed states and generation fields replace competing cancellation
  paths and obsolete readiness booleans; there is no compatibility fallback.
- Offline, deleted-graph, authentication, and transport failures remain visible as
  non-blocking `Sync_paused` banners while the current local mirror stays readable.
  Bounded retry resumes automatically when the failure is recoverable.

## Questions

None.
